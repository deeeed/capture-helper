/*
 * x11-grabber — occlusion-correct per-window capture for capture-helper (Linux/X11).
 *
 * This is the Linux replacement for the macOS ScreenCaptureKit path. It has two modes:
 *
 *   x11-grabber enumerate
 *       Print one JSON object per line describing every managed top-level window
 *       (EWMH _NET_CLIENT_LIST_STACKING), matching the field schema used by the
 *       macOS helper: {id,title,app,pid,width,height,x,y,layer,onScreen}.
 *
 *   x11-grabber capture <xid> [--fps N] [--frames K]
 *       Composite-redirect the window and write raw BGRA frames to stdout at N fps.
 *       A single startup line is written to stderr so the parent knows the frame size:
 *           {"type":"grab_start","xid":N,"width":W,"height":H,"depth":D}
 *       With --frames 1 it grabs a single frame and exits (used by `snapshot`).
 *
 * Capture is occlusion-correct: XCompositeNameWindowPixmap gives the window's own
 * backing store, so other windows on top (or the window being partly offscreen) do
 * not corrupt the output. ffmpeg (spawned by the Node backend) does scaling/encoding.
 *
 * Exit codes:
 *    0  clean exit (EOF on stdout / --frames satisfied)
 *   64  usage error
 *   65  cannot open display
 *   66  required X extension missing (Composite)
 *   67  window not found / bad geometry
 *   75  window resized — parent should restart the pipe at the new size
 *   76  window destroyed/unmapped — parent should drop the slot
 *   77  X error / grab failure
 */

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xcomposite.h>
#include <X11/extensions/XShm.h>

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <time.h>
#include <unistd.h>

/* ---- small helpers ---------------------------------------------------- */

static Display *dpy = NULL;
static Window root = 0;

/* Xlib's default error handler calls exit() on protocol errors. For a long-lived
 * grabber whose target window can be destroyed/resized mid-call (BadWindow/
 * BadDrawable/BadMatch), we trap errors instead and let the capture loop convert
 * them into controlled lifecycle exit codes. */
static volatile int g_xerror = 0;
static int xerror_handler(Display *d, XErrorEvent *e) { (void)d; (void)e; g_xerror = 1; return 0; }

static Atom A(const char *name) { return XInternAtom(dpy, name, False); }

/* Fetch a window property. Caller must XFree(*out) on success. Returns item count. */
static unsigned long get_prop(Window w, Atom prop, Atom type, unsigned char **out) {
    Atom actual_type;
    int actual_fmt;
    unsigned long nitems = 0, bytes_after = 0;
    *out = NULL;
    if (XGetWindowProperty(dpy, w, prop, 0, (~0L), False, type,
                           &actual_type, &actual_fmt, &nitems, &bytes_after, out) != Success) {
        return 0;
    }
    if (!*out) return 0;
    return nitems;
}

static pid_t window_pid(Window w) {
    unsigned char *data = NULL;
    pid_t pid = 0;
    if (get_prop(w, A("_NET_WM_PID"), XA_CARDINAL, &data) >= 1 && data) {
        pid = (pid_t)(*(unsigned long *)data);
    }
    if (data) XFree(data);
    return pid;
}

/* _NET_WM_NAME (UTF-8) preferred, fall back to WM_NAME. Returns malloc'd string or NULL. */
static char *window_title(Window w) {
    unsigned char *data = NULL;
    char *title = NULL;
    if (get_prop(w, A("_NET_WM_NAME"), A("UTF8_STRING"), &data) >= 1 && data) {
        title = strdup((char *)data);
        XFree(data);
        return title;
    }
    if (data) { XFree(data); data = NULL; }

    XTextProperty tp;
    if (XGetWMName(dpy, w, &tp) && tp.value) {
        title = strdup((char *)tp.value);
        XFree(tp.value);
    }
    return title;
}

/* WM_CLASS second field (the class, e.g. "Google-chrome"). Returns malloc'd or NULL. */
static char *window_app(Window w) {
    XClassHint hint = {0};
    char *app = NULL;
    if (XGetClassHint(dpy, w, &hint)) {
        if (hint.res_class) app = strdup(hint.res_class);
        if (hint.res_name) XFree(hint.res_name);
        if (hint.res_class) XFree(hint.res_class);
    }
    return app;
}

static int window_hidden(Window w) {
    unsigned char *data = NULL;
    Atom hidden = A("_NET_WM_STATE_HIDDEN");
    int is_hidden = 0;
    unsigned long n = get_prop(w, A("_NET_WM_STATE"), XA_ATOM, &data);
    if (data) {
        Atom *states = (Atom *)data;
        for (unsigned long i = 0; i < n; i++) {
            if (states[i] == hidden) { is_hidden = 1; break; }
        }
        XFree(data);
    }
    return is_hidden;
}

/* layer: mimic macOS windowLayer==0 capturable filter. NORMAL/no-type => 0, else 1. */
static int window_layer(Window w) {
    unsigned char *data = NULL;
    Atom normal = A("_NET_WM_WINDOW_TYPE_NORMAL");
    int layer = 0;
    unsigned long n = get_prop(w, A("_NET_WM_WINDOW_TYPE"), XA_ATOM, &data);
    if (data) {
        if (n >= 1) {
            Atom first = ((Atom *)data)[0];
            layer = (first == normal) ? 0 : 1;
        }
        XFree(data);
    }
    return layer;
}

/* JSON-escape a C string to stdout. NULL -> empty. */
static void json_print_escaped(FILE *f, const char *s) {
    fputc('"', f);
    if (s) {
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            switch (*p) {
                case '"':  fputs("\\\"", f); break;
                case '\\': fputs("\\\\", f); break;
                case '\n': fputs("\\n", f); break;
                case '\r': fputs("\\r", f); break;
                case '\t': fputs("\\t", f); break;
                default:
                    if (*p < 0x20) fprintf(f, "\\u%04x", *p);
                    else fputc(*p, f);
            }
        }
    }
    fputc('"', f);
}

/* ---- enumerate -------------------------------------------------------- */

static int mode_enumerate(void) {
    unsigned char *data = NULL;
    unsigned long n = get_prop(root, A("_NET_CLIENT_LIST_STACKING"), XA_WINDOW, &data);
    if (n == 0) {
        if (data) { XFree(data); data = NULL; }
        n = get_prop(root, A("_NET_CLIENT_LIST"), XA_WINDOW, &data);
    }
    Window *wins = (Window *)data;

    XWindowAttributes rootattr;
    XGetWindowAttributes(dpy, root, &rootattr);

    for (unsigned long i = 0; i < n; i++) {
        Window w = wins[i];
        XWindowAttributes a;
        if (!XGetWindowAttributes(dpy, w, &a)) continue;
        if (a.width <= 0 || a.height <= 0) continue;

        int rx = 0, ry = 0;
        Window child;
        XTranslateCoordinates(dpy, w, root, 0, 0, &rx, &ry, &child);

        char *title = window_title(w);
        char *app = window_app(w);
        pid_t pid = window_pid(w);
        int hidden = window_hidden(w);
        int layer = window_layer(w);

        int viewable = (a.map_state == IsViewable) && !hidden;
        int onscreen = viewable &&
                       (rx + a.width > 0) && (ry + a.height > 0) &&
                       (rx < rootattr.width) && (ry < rootattr.height);

        printf("{\"id\":%lu,\"title\":", (unsigned long)w);
        json_print_escaped(stdout, title);
        printf(",\"app\":");
        json_print_escaped(stdout, app);
        printf(",\"pid\":%ld,\"width\":%d,\"height\":%d,\"x\":%d,\"y\":%d,\"layer\":%d,\"onScreen\":%s}\n",
               (long)pid, a.width, a.height, rx, ry, layer, onscreen ? "true" : "false");

        free(title);
        free(app);
    }
    if (data) XFree(data);
    fflush(stdout);
    return 0;
}

/* ---- check (doctor) --------------------------------------------------- */

static int mode_check(void) {
    int ev, err;
    int composite = XCompositeQueryExtension(dpy, &ev, &err) ? 1 : 0;
    int shm = XShmQueryExtension(dpy) ? 1 : 0;
    XWindowAttributes a;
    int rootok = XGetWindowAttributes(dpy, root, &a) ? 1 : 0;
    printf("{\"composite\":%s,\"shm\":%s,\"root\":%s,\"screenWidth\":%d,\"screenHeight\":%d}\n",
           composite ? "true" : "false", shm ? "true" : "false",
           rootok ? "true" : "false", rootok ? a.width : 0, rootok ? a.height : 0);
    fflush(stdout);
    return composite ? 0 : 66;
}

/* ---- capture ---------------------------------------------------------- */

typedef struct {
    XShmSegmentInfo shminfo;
    XImage *image;
    int w, h;
    int use_shm;
} Frame;

static void frame_destroy(Frame *fr) {
    if (!fr->image) return;
    if (fr->use_shm) {
        XShmDetach(dpy, &fr->shminfo);
        fr->image->data = NULL;        /* shared memory: not Xfree-able, detach below */
        XDestroyImage(fr->image);
        if (fr->shminfo.shmaddr && fr->shminfo.shmaddr != (char *)-1) shmdt(fr->shminfo.shmaddr);
    } else {
        XDestroyImage(fr->image);      /* frees the malloc'd data */
    }
    fr->image = NULL;
}

static int frame_create(Frame *fr, Visual *visual, int depth, int w, int h, int want_shm) {
    memset(fr, 0, sizeof(*fr));
    fr->w = w; fr->h = h;

    if (want_shm) {
        fr->image = XShmCreateImage(dpy, visual, depth, ZPixmap, NULL, &fr->shminfo, w, h);
        if (fr->image) {
            fr->shminfo.shmid = shmget(IPC_PRIVATE,
                                       (size_t)fr->image->bytes_per_line * fr->image->height,
                                       IPC_CREAT | 0600);
            if (fr->shminfo.shmid != -1) {
                char *addr = (char *)shmat(fr->shminfo.shmid, NULL, 0);
                if (addr != (char *)-1) {
                    fr->shminfo.shmaddr = fr->image->data = addr;
                    fr->shminfo.readOnly = False;
                    g_xerror = 0;
                    if (XShmAttach(dpy, &fr->shminfo)) {
                        XSync(dpy, False);       /* surface async BadAccess (e.g. remote display) */
                        if (!g_xerror) {
                            shmctl(fr->shminfo.shmid, IPC_RMID, NULL); /* freed on last detach */
                            fr->use_shm = 1;
                            return 1;
                        }
                        XShmDetach(dpy, &fr->shminfo); /* server rejected attach: undo, fall back */
                        g_xerror = 0;
                    }
                    shmdt(addr);                 /* attach failed: detach this mapping */
                    fr->image->data = NULL;
                }
                shmctl(fr->shminfo.shmid, IPC_RMID, NULL); /* never leak the segment */
            }
            fr->image->data = NULL;              /* don't let XDestroyImage free shm/invalid ptr */
            XDestroyImage(fr->image);
            fr->image = NULL;
        }
    }

    /* fallback: plain XImage (e.g. remote display without MIT-SHM) */
    fr->use_shm = 0;
    fr->image = XCreateImage(dpy, visual, depth, ZPixmap, 0, NULL, w, h, 32, 0);
    if (!fr->image) return 0;
    fr->image->data = malloc((size_t)fr->image->bytes_per_line * fr->image->height);
    if (!fr->image->data) { XDestroyImage(fr->image); fr->image = NULL; return 0; }
    return 1;
}

/* write one BGRA frame to stdout, stripping row padding.
 * returns 0 = ok, 1 = downstream closed (clean stop), -1 = real write error. */
static int write_frame(Frame *fr) {
    const XImage *img = fr->image;
    const int rowbytes = fr->w * 4;
    for (int y = 0; y < fr->h; y++) {
        const char *row = img->data + (size_t)y * img->bytes_per_line;
        size_t off = 0;
        while (off < (size_t)rowbytes) {
            ssize_t n = write(STDOUT_FILENO, row + off, (size_t)rowbytes - off);
            if (n > 0) { off += (size_t)n; continue; }
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue; /* retry */
            if (n < 0 && errno == EPIPE) return 1;  /* consumer (ffmpeg) closed the pipe */
            return -1;                              /* unexpected write failure */
        }
    }
    return 0;
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static int grab_into(Frame *fr, Pixmap pm) {
    if (fr->use_shm) {
        if (!XShmGetImage(dpy, pm, fr->image, 0, 0, AllPlanes)) return -1;
    } else {
        if (!XGetSubImage(dpy, pm, 0, 0, fr->w, fr->h, AllPlanes, ZPixmap, fr->image, 0, 0))
            return -1;
    }
    return 0;
}

static int mode_capture(Window win, int fps, long max_frames) {
    int comp_ev, comp_err;
    if (!XCompositeQueryExtension(dpy, &comp_ev, &comp_err)) {
        fprintf(stderr, "{\"type\":\"error\",\"msg\":\"XComposite extension unavailable\"}\n");
        return 66;
    }

    XWindowAttributes a;
    if (!XGetWindowAttributes(dpy, win, &a) || a.width <= 0 || a.height <= 0) {
        fprintf(stderr, "{\"type\":\"error\",\"msg\":\"window %lu has no geometry\"}\n", (unsigned long)win);
        return 67;
    }

    XCompositeRedirectWindow(dpy, win, CompositeRedirectAutomatic);
    XSelectInput(dpy, win, StructureNotifyMask);
    XSync(dpy, False);

    int w = a.width, h = a.height, depth = a.depth;
    Visual *visual = a.visual;
    Pixmap pm = XCompositeNameWindowPixmap(dpy, win);
    if (!pm) {
        fprintf(stderr, "{\"type\":\"error\",\"msg\":\"NameWindowPixmap failed\"}\n");
        return 77;
    }

    Frame fr;
    int want_shm = XShmQueryExtension(dpy) ? 1 : 0;
    if (!frame_create(&fr, visual, depth, w, h, want_shm)) {
        fprintf(stderr, "{\"type\":\"error\",\"msg\":\"image allocation failed\"}\n");
        return 77;
    }
    /* downstream assumes 32-bit BGRA (`ffmpeg -pix_fmt bgra`). Bail cleanly on exotic visuals
     * rather than emitting corrupt/overread rows. */
    if (fr.image->bits_per_pixel != 32) {
        fprintf(stderr, "{\"type\":\"error\",\"msg\":\"unsupported visual: %d bits/pixel (need 32)\"}\n",
                fr.image->bits_per_pixel);
        frame_destroy(&fr);
        return 67;
    }

    fprintf(stderr, "{\"type\":\"grab_start\",\"xid\":%lu,\"width\":%d,\"height\":%d,\"depth\":%d,\"shm\":%s}\n",
            (unsigned long)win, w, h, depth, fr.use_shm ? "true" : "false");
    fflush(stderr);

    long interval = 1000L / (fps > 0 ? fps : 15);
    if (interval < 1) interval = 1; /* cap absurd fps (>1000) so we don't busy-loop */
    int xfd = ConnectionNumber(dpy);
    long frames = 0;
    int rc = 0;
    long next = now_ms();
    g_xerror = 0; /* clear any setup-time protocol error before the capture loop */

    for (;;) {
        /* drain X events: detect resize / destroy */
        while (XPending(dpy)) {
            XEvent ev;
            XNextEvent(dpy, &ev);
            if (ev.type == DestroyNotify || ev.type == UnmapNotify) {
                fprintf(stderr, "{\"type\":\"gone\",\"xid\":%lu}\n", (unsigned long)win);
                rc = 76; goto done;
            }
            if (ev.type == ConfigureNotify) {
                if (ev.xconfigure.width != w || ev.xconfigure.height != h) {
                    fprintf(stderr, "{\"type\":\"resized\",\"xid\":%lu,\"width\":%d,\"height\":%d}\n",
                            (unsigned long)win, ev.xconfigure.width, ev.xconfigure.height);
                    rc = 75; goto done;
                }
                /* move only: named pixmap is still valid, keep going */
            }
        }

        /* emit at most one frame per interval; X events wake us but never add frames */
        long now = now_ms();
        if (now >= next) {
            if (grab_into(&fr, pm) != 0 || g_xerror) {
                /* classify the failure instead of always assuming the window is gone */
                g_xerror = 0;
                XWindowAttributes na;
                if (!XGetWindowAttributes(dpy, win, &na)) {
                    fprintf(stderr, "{\"type\":\"gone\",\"xid\":%lu}\n", (unsigned long)win);
                    rc = 76; goto done;
                }
                if (na.width != w || na.height != h) {
                    fprintf(stderr, "{\"type\":\"resized\",\"xid\":%lu,\"width\":%d,\"height\":%d}\n",
                            (unsigned long)win, na.width, na.height);
                    rc = 75; goto done;
                }
                /* same geometry: the named pixmap may be stale — re-name and retry once */
                XFreePixmap(dpy, pm);
                pm = XCompositeNameWindowPixmap(dpy, win);
                g_xerror = 0;
                if (!pm || grab_into(&fr, pm) != 0 || g_xerror) {
                    fprintf(stderr, "{\"type\":\"error\",\"msg\":\"grab failed\",\"xid\":%lu}\n", (unsigned long)win);
                    rc = 77; goto done;
                }
            }
            int wr = write_frame(&fr);
            if (wr == 1) { rc = 0; goto done; }   /* downstream closed: normal stop */
            if (wr < 0) { fprintf(stderr, "{\"type\":\"error\",\"msg\":\"stdout write failed\"}\n"); rc = 77; goto done; }
            if (++frames >= max_frames && max_frames > 0) { rc = 0; goto done; }
            next += interval;
            if (next <= now) next = now + interval; /* fell behind: resync, don't burst */
        }

        long wait = next - now_ms();
        if (wait < 0) wait = 0;
        struct pollfd pfd = { .fd = xfd, .events = POLLIN };
        poll(&pfd, 1, (int)wait); /* wake early if X events arrive */
    }

done:
    frame_destroy(&fr);
    if (pm) XFreePixmap(dpy, pm);
    return rc;
}

/* ---- main ------------------------------------------------------------- */

static void usage(void) {
    fprintf(stderr,
        "usage: x11-grabber enumerate\n"
        "       x11-grabber capture <xid> [--fps N] [--frames K]\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 64; }

    dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "{\"type\":\"error\",\"msg\":\"cannot open DISPLAY '%s'\"}\n",
                getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)");
        return 65;
    }
    root = DefaultRootWindow(dpy);
    XSetErrorHandler(xerror_handler);  /* trap protocol errors instead of exiting */
    signal(SIGPIPE, SIG_IGN);          /* a closed stdout must yield EPIPE, not kill us */

    int rc;
    if (strcmp(argv[1], "enumerate") == 0) {
        rc = mode_enumerate();
    } else if (strcmp(argv[1], "check") == 0) {
        rc = mode_check();
    } else if (strcmp(argv[1], "capture") == 0) {
        if (argc < 3) { usage(); rc = 64; goto out; }
        Window win = (Window)strtoul(argv[2], NULL, 0);
        int fps = 15;
        long frames = 0;
        for (int i = 3; i < argc; i++) {
            if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) fps = atoi(argv[++i]);
            else if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) frames = atol(argv[++i]);
            else { usage(); rc = 64; goto out; }
        }
        if (win == 0) { fprintf(stderr, "{\"type\":\"error\",\"msg\":\"invalid xid\"}\n"); rc = 67; goto out; }
        rc = mode_capture(win, fps, frames);
    } else {
        usage();
        rc = 64;
    }

out:
    XCloseDisplay(dpy);
    return rc;
}

import Darwin
import Foundation

/// replayd identifies unbundled clients by executable path. A second process
/// exiting can therefore stop the first process's streams. Keep every SCK
/// command exclusive for its lifetime, including enumeration-only commands.
enum CaptureAccess {
    private static var descriptor: Int32 = -1

    static func acquire() throws {
        if descriptor >= 0 { return }
        // Use a host path, not TMPDIR: GUI and SSH launchers can have different
        // temporary directories. replayd clients belong to the login user.
        let path = ProcessInfo.processInfo.environment["CAPTURE_HELPER_TEST_ACCESS_PATH"]
            ?? "/tmp/capture-helper-\(getuid()).lock"
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CaptureError.setupFailed("cannot open capture access lock: \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(fd)
            if failure == EWOULDBLOCK {
                throw CaptureError.captureBusy("another capture-helper command is using ScreenCaptureKit on this host; wait for it to finish")
            }
            throw CaptureError.setupFailed("cannot acquire capture access lock: \(String(cString: strerror(failure)))")
        }
        // Never unlink the file: a new inode would allow a second owner.
        // The kernel releases the lock on process exit, including crashes.
        descriptor = fd
    }
}

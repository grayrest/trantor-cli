# Runs the app on a pty, sends one line and ONE Ctrl-D, and prints what it
# wrote. Exits nonzero if it has not finished five seconds after the Ctrl-D.
import os, pty, select, sys, termios, time

pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], "eof"])
# No echo, so the terminal does not print the line and the ^D back at us.
attrs = termios.tcgetattr(fd)
attrs[3] &= ~termios.ECHO
termios.tcsetattr(fd, termios.TCSANOW, attrs)
os.write(fd, b"a\n")
time.sleep(0.2)
os.write(fd, b"\x04")
out, deadline = b"", time.time() + 5
while time.time() < deadline:
    if select.select([fd], [], [], deadline - time.time())[0]:
        try:
            chunk = os.read(fd, 1024)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if os.waitpid(pid, os.WNOHANG)[0]:
        break
else:
    os.kill(pid, 9)
    print("timed out; the app was still waiting. Saw: %r" % out, file=sys.stderr)
    sys.exit(1)
lines = [l.strip() for l in out.decode(errors="replace").splitlines() if l.strip()]
print(lines[-1] if lines else "")

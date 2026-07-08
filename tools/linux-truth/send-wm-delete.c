/* send-wm-delete <window-id>: deliver a WM_DELETE_WINDOW client message
 * to an X11 window — the graceful close request a window manager would
 * send. Bare Xvfb has no window manager, and XDestroyWindow-style tools
 * kill the window out from under the toolkit (which aborts); this is the
 * honest way to exercise an app's own close path headlessly.
 *
 * Build: zig cc -o send-wm-delete send-wm-delete.c -lX11
 */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: send-wm-delete <window-id>\n");
        return 2;
    }
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "cannot open display\n");
        return 1;
    }
    Window win = (Window)strtoul(argv[1], NULL, 0);
    XEvent ev = {0};
    ev.xclient.type = ClientMessage;
    ev.xclient.window = win;
    ev.xclient.message_type = XInternAtom(dpy, "WM_PROTOCOLS", False);
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = (long)XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    ev.xclient.data.l[1] = CurrentTime;
    if (!XSendEvent(dpy, win, False, NoEventMask, &ev)) {
        fprintf(stderr, "XSendEvent failed\n");
        XCloseDisplay(dpy);
        return 1;
    }
    XFlush(dpy);
    XCloseDisplay(dpy);
    return 0;
}

#include "PNGShim.h"
#include <stdlib.h>
#include <string.h>

int swift_png_safe_read(
    png_structp png_ptr,
    png_infop info_ptr,
    void (*read_fn)(png_structp, png_bytep, png_size_t),
    void *io_ptr
) {
    if (setjmp(png_jmpbuf(png_ptr))) {
        return 0; // signal error
    }

    png_set_read_fn(png_ptr, io_ptr, read_fn);
    png_read_info(png_ptr, info_ptr);
    return 1;
}

typedef struct SwiftPNGErrorState {
    char message[512];
    char warning[512];
    void *warning_ctx;
    void (*warning_cb)(void *ctx, const char *msg);
} SwiftPNGErrorState;

// Warning handler; capture and optionally forward to Swift.
static void swift_png_warning_forward(png_structp png_ptr, png_const_charp msg) {
    SwiftPNGErrorState *state = (SwiftPNGErrorState *)png_get_error_ptr(png_ptr);
    if (state != NULL) {
        if (msg != NULL) {
            strncpy(state->warning, msg, sizeof(state->warning) - 1);
            state->warning[sizeof(state->warning) - 1] = '\0';
        } else {
            state->warning[0] = '\0';
        }
        if (state->warning_cb != NULL) {
            state->warning_cb(state->warning_ctx, state->warning);
        }
    }
}

// Error handler that never returns; jumps back to setjmp site.
static void swift_png_error_longjmp(png_structp png_ptr, png_const_charp msg) {
    SwiftPNGErrorState *state = (SwiftPNGErrorState *)png_get_error_ptr(png_ptr);
    if (state != NULL) {
        if (msg != NULL) {
            strncpy(state->message, msg, sizeof(state->message) - 1);
            state->message[sizeof(state->message) - 1] = '\0';
        } else {
            state->message[0] = '\0';
        }
    }
    png_longjmp(png_ptr, 1);
}

void swift_png_set_error_handlers(png_structp png_ptr) {
    SwiftPNGErrorState *state = (SwiftPNGErrorState *)malloc(sizeof(SwiftPNGErrorState));
    if (state != NULL) {
        state->message[0] = '\0';
        state->warning[0] = '\0';
        state->warning_ctx = NULL;
        state->warning_cb = NULL;
    }
    png_set_error_fn(png_ptr, state, swift_png_error_longjmp, swift_png_warning_forward);
}

void swift_png_clear_error_handlers(png_structp png_ptr) {
    SwiftPNGErrorState *state = (SwiftPNGErrorState *)png_get_error_ptr(png_ptr);
    if (state != NULL) {
        free(state);
    }
    png_set_error_fn(png_ptr, NULL, NULL, NULL);
}

const char *swift_png_get_last_error(png_structp png_ptr) {
    SwiftPNGErrorState *state = (SwiftPNGErrorState *)png_get_error_ptr(png_ptr);
    if (state == NULL) {
        return NULL;
    }
    if (state->message[0] == '\0') {
        return NULL;
    }
    return state->message;
}

const char *swift_png_get_last_warning(png_structp png_ptr) {
    SwiftPNGErrorState *state = (SwiftPNGErrorState *)png_get_error_ptr(png_ptr);
    if (state == NULL) {
        return NULL;
    }
    if (state->warning[0] == '\0') {
        return NULL;
    }
    return state->warning;
}

void swift_png_set_warning_callback(png_structp png_ptr, swift_png_warning_cb cb, void *ctx) {
    SwiftPNGErrorState *state = (SwiftPNGErrorState *)png_get_error_ptr(png_ptr);
    if (state != NULL) {
        state->warning_cb = cb;
        state->warning_ctx = ctx;
    }
}

int swift_png_safe_read_update_info(png_structp png_ptr, png_infop info_ptr) {
    if (setjmp(png_jmpbuf(png_ptr))) {
        return 0;
    }
    png_read_update_info(png_ptr, info_ptr);
    return 1;
}

int swift_png_safe_read_row(png_structp png_ptr, png_bytep row, png_bytep display_row) {
    if (setjmp(png_jmpbuf(png_ptr))) {
        return 0;
    }
    png_read_row(png_ptr, row, display_row);
    return 1;
}

int swift_png_safe_read_end(png_structp png_ptr, png_infop info_ptr) {
    if (setjmp(png_jmpbuf(png_ptr))) {
        return 0;
    }
    png_read_end(png_ptr, info_ptr);
    return 1;
}

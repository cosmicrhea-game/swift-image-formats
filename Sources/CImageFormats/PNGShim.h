#include <png.h>

int swift_png_safe_read(
    png_structp png_ptr,
    png_infop info_ptr,
    void (*read_fn)(png_structp, png_bytep, png_size_t),
    void *io_ptr
);

// Set custom error and warning handlers that do not print and never return.
// The error handler calls png_longjmp to unwind back to the nearest setjmp.
void swift_png_set_error_handlers(png_structp png_ptr);
// Free any error handler state and reset handlers
void swift_png_clear_error_handlers(png_structp png_ptr);
// Get the last error message captured by the error handler (nullable)
const char *swift_png_get_last_error(png_structp png_ptr);
// Get the last warning message captured by the warning handler (nullable)
const char *swift_png_get_last_warning(png_structp png_ptr);

// Optional: forward warnings to Swift via callback
typedef void (*swift_png_warning_cb)(void *ctx, const char *msg);
void swift_png_set_warning_callback(png_structp png_ptr, swift_png_warning_cb cb, void *ctx);

// Wrap additional libpng read APIs with setjmp protection.
int swift_png_safe_read_update_info(png_structp png_ptr, png_infop info_ptr);
int swift_png_safe_read_row(png_structp png_ptr, png_bytep row, png_bytep display_row);
int swift_png_safe_read_end(png_structp png_ptr, png_infop info_ptr);

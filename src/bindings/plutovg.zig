//! Bindings for PlutoVG, an immediate-mode 2D vector graphics engine.
const std = @import("std");
const c = @import("c");
const assets = @import("assets");

// For now just load one font globally.
pub var plutovg_font: ?*c.plutovg_font_face_t = null;

pub fn loadEmbeddedFont(font_data: []const u8) void {
    plutovg_font = c.plutovg_font_face_load_from_data(
        font_data.ptr,
        @intCast(font_data.len),
        0, // ttcindex (0 for standard .ttf)
        null, // destroy_func (null because memory is static)
        null, // closure
    );
}

/// Pixel buffer.
///
/// Holds premultiplied ARGB pixels (32 bits per pixel; on a little-endian host
/// the in-memory byte order is B G R A).
pub const Surface = struct {
    ptr: *c.plutovg_surface_t,

    /// Creates an image surface using existing pixel data.
    ///
    /// data: Pointer to the pixel data.
    /// width: The width of the surface in pixels.
    /// height: The height of the surface in pixels.
    /// stride: The number of pixels per row in the pixel data.
    pub fn initForData(data_ptr: [*]u8, width: u32, height: u32, stride: u32) !Surface {
        const surface = c.plutovg_surface_create_for_data(
            data_ptr,
            @intCast(width),
            @intCast(height),
            @intCast(stride * 4),
        ) orelse return error.SurfaceFailed;
        return .{ .ptr = surface };
    }

    pub fn deinit(surface: *const Surface) void {
        c.plutovg_surface_destroy(surface.ptr);
    }
};

/// Drawing context.
///
/// The canvas inherits the surface's dimensions; it never owns the surface, so
/// always destroy in the reverse order of creation.
pub const Canvas = struct {
    ptr: *c.plutovg_canvas_t,
    surface: ?Surface = null,

    pub const Options = struct {
        font_size: f32 = 12.0,
    };

    pub fn init(surface: *const Surface, opts: Options) !Canvas {
        const canvas = c.plutovg_canvas_create(surface.ptr) orelse return error.CanvasFailed;
        if (plutovg_font == null) loadEmbeddedFont(assets.fonts.dejavu_sans);
        if (plutovg_font) |font| {
            c.plutovg_canvas_set_font(canvas, font, opts.font_size);
        } else {
            std.log.warn("Canvas font failed to load", .{});
        }
        return .{ .ptr = canvas };
    }

    /// Creates a canvas with internally managed Surface.
    ///
    /// data: Pointer to the pixel data.
    /// width: The width of the surface in pixels.
    /// height: The height of the surface in pixels.
    /// stride: The number of pixels per row in the pixel data.
    pub fn initForData(data_ptr: [*]u8, width: u32, height: u32, stride: u32) !Canvas {
        const surface = try Surface.initForData(data_ptr, width, height, stride);
        var canvas = try Canvas.init(&surface, .{});
        canvas.surface = surface;
        return canvas;
    }

    pub fn deinit(canvas: *const Canvas) void {
        c.plutovg_canvas_destroy(canvas.ptr);
        if (canvas.surface) |surface| surface.deinit();
    }

    pub fn save(canvas: *const Canvas) void {
        c.plutovg_canvas_save(canvas.ptr);
    }

    pub fn restore(canvas: *const Canvas) void {
        c.plutovg_canvas_restore(canvas.ptr);
    }

    /// Calling this function does not draw anything onto the screen
    /// immediately. Instead, it creates or modifies a plutovg_paint_t object
    /// embedded inside the current graphics state. The canvas remembers this
    /// color as the active "brush" or "fill" source until you explicitly change
    /// it or restore a previous state.
    pub fn setRGBA(canvas: *const Canvas, r: f32, g: f32, b: f32, a: f32) void {
        c.plutovg_canvas_set_rgba(canvas.ptr, r, g, b, a);
    }

    pub fn setLineWidth(canvas: *const Canvas, line_width: f32) void {
        c.plutovg_canvas_set_line_width(canvas.ptr, line_width);
    }

    /// Moves the current point to a new position.
    ///
    /// Moves the current point to the specified coordinates without adding a
    /// line.  This operation is added to the current path.
    pub fn moveTo(canvas: *const Canvas, x: f32, y: f32) void {
        c.plutovg_canvas_move_to(canvas.ptr, x, y);
    }

    /// Adds a straight line segment to the current path.
    ///
    /// Adds a straight line from the current point to the specified
    /// coordinates.  This segment is added to the current path.
    pub fn lineTo(canvas: *const Canvas, x: f32, y: f32) void {
        c.plutovg_canvas_line_to(canvas.ptr, x, y);
    }

    /// Closes the current path by adding a straight line back to the starting
    /// point.
    pub fn closePath(canvas: *const Canvas) void {
        c.plutovg_canvas_close_path(canvas.ptr);
    }

    /// Adds a cubic Bézier curve to the current path.
    ///
    /// Adds a cubic Bézier curve from the current point to the specified end
    /// point, using the given control points. This curve is added to the
    /// current path.
    pub fn cubicTo(canvas: *const Canvas, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) void {
        c.plutovg_canvas_cubic_to(canvas.ptr, x1, y1, x2, y2, x3, y3);
    }

    /// Drawing the outline of a path.
    pub fn stroke(canvas: *const Canvas) void {
        c.plutovg_canvas_stroke(canvas.ptr);
    }

    /// Fills the entire visible canvas (bounded by the current clipping region)
    /// with the current paint source.
    pub fn paint(canvas: *const Canvas) void {
        c.plutovg_canvas_paint(canvas.ptr);
    }

    pub const Operator = enum(c_int) {
        /// Clears the destination (resulting in a fully transparent image).
        clear = c.PLUTOVG_OPERATOR_CLEAR,
        /// Source replaces destination.
        src = c.PLUTOVG_OPERATOR_SRC,
        /// Destination is kept, source is ignored.
        dst = c.PLUTOVG_OPERATOR_DST,
        /// Source is composited over destination.
        src_over = c.PLUTOVG_OPERATOR_SRC_OVER,
        /// Destination is composited over source.
        dst_over = c.PLUTOVG_OPERATOR_DST_OVER,
        /// Source within destination (only the overlapping part of source is shown).
        src_in = c.PLUTOVG_OPERATOR_SRC_IN,
        /// Destination within source.
        dst_in = c.PLUTOVG_OPERATOR_DST_IN,
        /// Source outside destination (non-overlapping part of source is shown).
        src_out = c.PLUTOVG_OPERATOR_SRC_OUT,
        /// Destination outside source.
        dst_out = c.PLUTOVG_OPERATOR_DST_OUT,
        /// Source atop destination (source shown over destination but only in the destination's bounds).
        src_atop = c.PLUTOVG_OPERATOR_SRC_ATOP,
        /// Destination atop source (destination shown over source but only in the source's bounds).
        dst_atop = c.PLUTOVG_OPERATOR_DST_ATOP,
        /// Source and destination are combined, but their overlapping regions are cleared.
        xor = c.PLUTOVG_OPERATOR_XOR,
    };

    /// Defines the Compositing Math used when new pixels overlay existing ones.
    ///
    /// When you draw something, PlutoVG determines what the pixel color should
    /// look like using an internal blending equation. Changing the operator
    /// updates the flags that tell the scanline rasterizer how to execute this
    /// math. For example, the default SRC_OVER draws the new color on top of
    /// the old one while honoring alpha transparency. SRC completely deletes
    /// the old pixel and replaces it, ignoring any alpha blending.
    pub fn setOperator(canvas: *const Canvas, operator: Operator) void {
        c.plutovg_canvas_set_operator(canvas.ptr, @intCast(@intFromEnum(operator)));
    }

    /// Translates the current transformation matrix by given offsets.
    pub fn translate(canvas: *const Canvas, x_offset: f32, y_offset: f32) void {
        c.plutovg_canvas_translate(canvas.ptr, x_offset, y_offset);
    }

    /// Scales the current transformation matrix by given factors.
    pub fn scale(canvas: *const Canvas, x_factor: f32, y_factor: f32) void {
        c.plutovg_canvas_scale(canvas.ptr, x_factor, y_factor);
    }

    /// Adds a circle centered at the specified coordinates with the given
    /// radius to the current path.
    pub fn circle(canvas: *const Canvas, cx: f32, cy: f32, r: f32) void {
        c.plutovg_canvas_circle(canvas.ptr, cx, cy, r);
    }

    /// A drawing operator that fills the current path according to the current fill rule.
    ///
    /// The current path will be cleared after this operation.
    pub fn fill(canvas: *const Canvas) void {
        c.plutovg_canvas_fill(canvas.ptr);
    }

    /// A drawing operator that fills the current path according to the current
    /// fill rule.
    /// 
    /// The current path will be preserved after this operation.
    pub fn fillPreserve(canvas: *const Canvas) void {
        c.plutovg_canvas_fill_preserve(canvas.ptr);
    }

    /// TODO Hacky vibed, fix
    pub fn drawText(canvas: *const Canvas, text: []const u8, size: f32) void {
        if (plutovg_font) |font| {
            var extents: c.plutovg_rect_t = undefined;
            const adv = c.plutovg_font_face_text_extents(
                font,
                size,
                text.ptr,
                @intCast(text.len),
                c.PLUTOVG_TEXT_ENCODING_UTF8,
                &extents,
            );

            // Center horizontally and vertically
            const tx_label = -adv / 2.0;
            const ty_label = extents.h / 2.0;

            _ = c.plutovg_canvas_fill_text(
                canvas.ptr,
                text.ptr,
                @intCast(text.len),
                c.PLUTOVG_TEXT_ENCODING_UTF8,
                tx_label,
                ty_label,
            );
        }
    }
};


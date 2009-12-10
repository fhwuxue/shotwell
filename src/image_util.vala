/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

Gdk.Color parse_color(string spec) {
    return fetch_color(spec);
}

Gdk.Color fetch_color(string spec, Gdk.Drawable? drawable = null) {
    Gdk.Color color;
    if (!Gdk.Color.parse(spec, out color))
        error("Can't parse color %s", spec);
    
    if (drawable == null) {
        Gtk.Window app = AppWindow.get_instance();
        if (app != null)
            drawable = app.window;
    }
    
    if (drawable != null) {
        Gdk.Colormap colormap = drawable.get_colormap();
        if (colormap == null)
            error("Can't get colormap for drawable");
        
        if (!colormap.alloc_color(color, false, true))
            error("Can't allocate color %s", spec);
    }
    
    return color;
}

private inline uint32 convert_color(uint16 component) {
    return (uint32) (component / 256);
}

uint32 convert_rgba(Gdk.Color c, uint8 alpha) {
    return (convert_color(c.red) << 24) | (convert_color(c.green) << 16) | (convert_color(c.blue) << 8) 
        | alpha;
}

public enum Rotation {
    CLOCKWISE,
    COUNTERCLOCKWISE,
    MIRROR,
    UPSIDE_DOWN;
    
    public Gdk.Pixbuf perform(Gdk.Pixbuf pixbuf) {
        switch (this) {
            case CLOCKWISE:
                return pixbuf.rotate_simple(Gdk.PixbufRotation.CLOCKWISE);
            
            case COUNTERCLOCKWISE:
                return pixbuf.rotate_simple(Gdk.PixbufRotation.COUNTERCLOCKWISE);
            
            case MIRROR:
                return pixbuf.flip(true);
            
            case UPSIDE_DOWN:
                return pixbuf.flip(false);
            
            default:
                error("Unknown rotation: %d", (int) this);
                
                return pixbuf;
        }
    }
    
    public Rotation opposite() {
        switch (this) {
            case CLOCKWISE:
                return COUNTERCLOCKWISE;
            
            case COUNTERCLOCKWISE:
                return CLOCKWISE;
            
            case MIRROR:
            case UPSIDE_DOWN:
                return this;
            
            default:
                error("Unknown rotation: %d", (int) this);
                
                return this;
        }
    }
}

Gdk.Pixbuf scale_pixbuf(Gdk.Pixbuf pixbuf, int scale, Gdk.InterpType interp, bool scale_up) {
    Dimensions original = Dimensions.for_pixbuf(pixbuf);
    Dimensions scaled = original.get_scaled(scale, scale_up);
    if ((original.width == scaled.width) && (original.height == scaled.height))
        return pixbuf;

    return pixbuf.scale_simple(scaled.width, scaled.height, interp);
}

Gdk.Pixbuf resize_pixbuf(Gdk.Pixbuf pixbuf, Dimensions resized, Gdk.InterpType interp) {
    Dimensions original = Dimensions.for_pixbuf(pixbuf);
    if (original.width == resized.width && original.height == resized.height)
        return pixbuf;
    
    return pixbuf.scale_simple(resized.width, resized.height, interp);
}

inline uchar shift_color_byte(int b, int shift) {
    return (uchar) (b + shift).clamp(0, 255);
}

public void shift_colors(Gdk.Pixbuf pixbuf, int red, int green, int blue, int alpha) {
    assert(red >= -255 && red <= 255);
    assert(green >= -255 && green <= 255);
    assert(blue >= -255 && blue <= 255);
    assert(alpha >= -255 && alpha <= 255);
    
    int width = pixbuf.get_width();
    int height = pixbuf.get_height();
    int rowstride = pixbuf.get_rowstride();
    int channels = pixbuf.get_n_channels();
    uchar *pixels = pixbuf.get_pixels();

    assert(channels >= 3);
    assert(pixbuf.get_colorspace() == Gdk.Colorspace.RGB);
    assert(pixbuf.get_bits_per_sample() == 8);

    for (int y = 0; y < height; y++) {
        int y_offset = y * rowstride;
        
        for (int x = 0; x < width; x++) {
            int offset = y_offset + (x * channels);
            
            if (red != 0)
                pixels[offset] = shift_color_byte(pixels[offset], red);
            
            if (green != 0)
                pixels[offset + 1] = shift_color_byte(pixels[offset + 1], green);
            
            if (blue != 0)
                pixels[offset + 2] = shift_color_byte(pixels[offset + 2], blue);
            
            if (alpha != 0 && channels >= 4)
                pixels[offset + 3] = shift_color_byte(pixels[offset + 3], alpha);
        }
    }
}

bool coord_in_rectangle(int x, int y, Gdk.Rectangle rect) {
    return (x >= rect.x && x < (rect.x + rect.width) && y >= rect.y && y <= (rect.y + rect.height));
}

Gdk.Point coord_scaled_in_space(int x, int y, Dimensions original, Dimensions scaled) {
    double x_scale, y_scale;
    original.get_scale_ratios(scaled, out x_scale, out y_scale);
    
    Gdk.Point point = Gdk.Point();
    point.x = (int) Math.round(x * x_scale);
    point.y = (int) Math.round(y * y_scale);
    
    // watch for rounding errors
    if (point.x >= scaled.width)
        point.x = scaled.width - 1;
    
    if (point.y >= scaled.height)
        point.y = scaled.height - 1;
    
    return point;
}

// Can only scale a radius when the scale is proportional; returns -1 if not.  Only two points of
// precision are considered here.
int radius_scaled_in_space(int radius, Dimensions original, Dimensions scaled) {
    double x_scale, y_scale;
    original.get_scale_ratios(scaled, out x_scale, out y_scale);
    
    x_scale = Math.round(x_scale * 100.0) / 100.0;
    y_scale = Math.round(y_scale * 100.0) / 100.0;
    
    return (x_scale == y_scale) ? (int) Math.round(radius * x_scale) : -1;
}

namespace Jpeg {
    public const uint8 MARKER_PREFIX = 0xFF;
    
    public enum Marker {
        SOI = 0xD8,
        EOI = 0xD9,
        
        APP0 = 0xE0,
        APP1 = 0xE1;
        
        public uint8 get_byte() {
            return (uint8) this;
        }
    }
    
    public enum Quality {
        LOW = 50,
        MEDIUM = 75,
        HIGH = 90,
        MAXIMUM = 100;
        
        public int get_pct() {
            return (int) this;
        }
        
        public string get_pct_text() {
            return "%d".printf((int) this);
        }
        
        public string? to_string() {
            switch (this) {
                case LOW:
                    return _("Low (%d%%)").printf((int) this);
                
                case MEDIUM:
                    return _("Medium (%d%%)").printf((int) this);
                
                case HIGH:
                    return _("High (%d%%)").printf((int) this);
                    
                case MAXIMUM:
                    return _("Maximum (%d%%)").printf((int) this);
            }
            
            warn_if_reached();
            
            return null;
        }
    }
    
    public bool is_jpeg(File file) throws Error {
        FileInputStream fins = file.read(null);
        
        Marker marker;
        int segment_length = read_marker(fins, out marker);
        
        // for now, merely checking for SOI
        return (marker == Marker.SOI) && (segment_length == 0);
    }

    private int read_marker(FileInputStream fins, out Jpeg.Marker marker) throws Error {
        uint8 byte = 0;
        uint16 length = 0;
        size_t bytes_read;

        fins.read_all(&byte, 1, out bytes_read, null);
        if (byte != Jpeg.MARKER_PREFIX)
            return -1;
        
        fins.read_all(&byte, 1, out bytes_read, null);
        marker = (Jpeg.Marker) byte;
        if ((marker == Jpeg.Marker.SOI) || (marker == Jpeg.Marker.EOI)) {
            // no length
            return 0;
        }
        
        fins.read_all(&length, 2, out bytes_read, null);
        length = uint16.from_big_endian(length);
        if (length < 2) {
            debug("Invalid length %Xh at ofs %llXh", length, fins.tell() - 2);
            
            return -1;
        }
        
        // account for two length bytes already read
        return length - 2;
    }
    
    // this writes the marker and a length (if positive)
    private void write_marker(FileOutputStream fouts, Jpeg.Marker marker, int length) throws Error {
        // this is required to compile
        uint8 prefix = Jpeg.MARKER_PREFIX;
        uint8 byte = marker.get_byte();
        
        size_t written;
        fouts.write_all(&prefix, 1, out written, null);
        fouts.write_all(&byte, 1, out written, null);

        if (length <= 0)
            return;

        // +2 to account for length bytes
        length += 2;
        
        uint16 host = (uint16) length;
        uint16 motorola = (uint16) host.to_big_endian();

        fouts.write_all(&motorola, 2, out written, null);
    }
}

public class PhotoFileInterrogator {
    public enum Options {
        ALL,
        NO_MD5
    }
    
    private File file;
    private Options options;
    private bool size_ready = false;
    private bool pixbuf_prepared = false;
    private PhotoExif photo_exif = null;
    private string? md5 = null;
    private string format_name = "";
    private Dimensions dim = Dimensions();
    private Gdk.Colorspace colorspace = Gdk.Colorspace.RGB;
    private int channels = 0;
    private int bits_per_sample = 0;
    
    public PhotoFileInterrogator(File file, Options options) throws Error {
        this.file = file;
        this.options = options;
        
        interrogate();
    }
    
    private void interrogate() throws Error {
        // both of these flags are set when enough of the image is decoded
        size_ready = false;
        pixbuf_prepared = false;
        
        bool calc_md5 = options != Options.NO_MD5;
        
        // clear prior to interrogation
        photo_exif = null;
        md5 = "";
        dim = Dimensions();
        colorspace = Gdk.Colorspace.RGB;
        channels = 0;
        bits_per_sample = 0;
        
        // only give the loader enough of the image file to get basic information
        Gdk.PixbufLoader pixbuf_loader = new Gdk.PixbufLoader();
        pixbuf_loader.size_prepared += on_size_prepared;
        pixbuf_loader.area_prepared += on_area_prepared;
        
        // valac chokes on the ternary operator here
        Checksum? md5_checksum = null;
        if (calc_md5)
            md5_checksum = new Checksum(ChecksumType.MD5);
        
        // load EXIF
        photo_exif = new PhotoExif(file);
        
        // if no MD5, don't read as much, as the info will probably be gleaned
        // in the first 8K to 16K
        uint8[] buffer = (calc_md5) ? new uint8[64 * 1024] : new uint8[8 * 1024];
        size_t count = 0;
        
        // loop through until all conditions we're searching for are met
        FileInputStream fins = file.read(null);
        for (;;) {
            size_t bytes_read = fins.read(buffer, buffer.length, null);
            if (bytes_read <= 0)
                break;
            
            count += bytes_read;
            
            if (calc_md5)
                md5_checksum.update(buffer, bytes_read);
            
            // keep parsing the image until the size is discovered
            if (!size_ready || !pixbuf_prepared) {
                // because of bad bindings, PixbufLoader.write() only accepts the buffer reference,
                // not the length of data in the buffer, meaning partially-filled buffers need to 
                // be special-cased: https://bugzilla.gnome.org/show_bug.cgi?id=597870
                if (bytes_read == buffer.length) {
                    pixbuf_loader.write(buffer);
                } else {
                    uint8[] tmp = new uint8[bytes_read];
                    Memory.copy(tmp, buffer, bytes_read);
                    pixbuf_loader.write(tmp);
                }
            }
            
            // if not searching for anything else, exit
            if (!calc_md5 && size_ready && pixbuf_prepared)
                break;
        }
        
        // PixbufLoader throws an error if you close it with an incomplete image, so trap this
        try {
            pixbuf_loader.close();
        } catch (Error err) {
        }
            
        if (fins != null)
            fins.close(null);
        
        if (calc_md5)
            md5 = md5_checksum.get_string();
    }
    
    public bool has_exif() {
        return photo_exif.has_exif();
    }
    
    public PhotoExif? get_exif() {
        return photo_exif.has_exif() ? photo_exif : null;
    }
    
    public string? get_md5() {
        return md5;
    }
    
    public string get_format_name() {
        return format_name;
    }
    
    public Dimensions get_dimensions() {
        return dim;
    }
    
    public Gdk.Colorspace get_colorspace() {
        return colorspace;
    }
    
    public int get_channels() {
        return channels;
    }
    
    public int get_bits_per_sample() {
        return bits_per_sample;
    }
    
    private void on_size_prepared(int width, int height) {
        dim = Dimensions(width, height);
        size_ready = true;
    }
    
    private void on_area_prepared(Gdk.PixbufLoader pixbuf_loader) {
        Gdk.Pixbuf? pixbuf = pixbuf_loader.get_pixbuf();
        if (pixbuf == null)
            return;
        
        colorspace = pixbuf.get_colorspace();
        channels = pixbuf.get_n_channels();
        bits_per_sample = pixbuf.get_bits_per_sample();
        
        unowned Gdk.PixbufFormat format = pixbuf_loader.get_format();
        format_name = format.get_name();
        
        pixbuf_prepared = true;
    }
}


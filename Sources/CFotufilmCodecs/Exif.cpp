// The Exif record: read for the fields the engine uses (orientation, camera, lens, frame), and
// rewritten for exports the way the Mac app's ImageIO export keeps it.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>

namespace ffc {
namespace {

enum : uint16_t {
    tagOrientation = 0x0112, tagMake = 0x010F, tagModel = 0x0110, tagExifIFD = 0x8769,
    tagGPSIFD = 0x8825, tagInteropIFD = 0xA005, tagDNGVersion = 0xC612,
    tagFNumber = 0x829D, tagFocalLength = 0x920A, tagFocal35 = 0xA405,
    tagFocalPlaneX = 0xA20E, tagFocalPlaneY = 0xA20F, tagFocalPlaneUnit = 0xA210,
    tagLensMake = 0xA433, tagLensModel = 0xA434, tagMakerNote = 0x927C,
    tagPixelX = 0xA002, tagPixelY = 0xA003,
};

size_t typeSize(uint16_t type) {
    switch (type) {
    case 1: case 2: case 6: case 7: return 1;
    case 3: case 8: return 2;
    case 4: case 9: case 11: case 13: return 4;
    case 5: case 10: case 12: return 8;
    default: return 0;
    }
}

struct Entry {
    uint16_t tag, type;
    uint32_t count;
    /// The value's bytes in the record's own byte order.
    std::vector<uint8_t> value;
};

/// A TIFF structure read in its own byte order.
class Reader {
public:
    Reader(const uint8_t *data, size_t length) : data_(data), length_(length) {
        if (length < 8) throw Failure("short Exif record");
        if (data[0] == 'I' && data[1] == 'I') little_ = true;
        else if (data[0] == 'M' && data[1] == 'M') little_ = false;
        else throw Failure("not a TIFF structure");
        if (u16(2) != 42) throw Failure("not a TIFF structure");
    }
    bool little() const { return little_; }
    uint32_t firstIFD() const { return u32(4); }

    uint16_t u16(size_t at) const {
        check(at, 2);
        return little_ ? uint16_t(data_[at] | data_[at + 1] << 8)
                       : uint16_t(data_[at] << 8 | data_[at + 1]);
    }
    uint32_t u32(size_t at) const {
        check(at, 4);
        return little_ ? uint32_t(data_[at]) | uint32_t(data_[at + 1]) << 8
                             | uint32_t(data_[at + 2]) << 16 | uint32_t(data_[at + 3]) << 24
                       : uint32_t(data_[at]) << 24 | uint32_t(data_[at + 1]) << 16
                             | uint32_t(data_[at + 2]) << 8 | uint32_t(data_[at + 3]);
    }

    /// The entries of the directory at `offset`; an unreadable one ends the list.
    std::vector<Entry> directory(uint32_t offset) const {
        std::vector<Entry> entries;
        if (offset == 0 || offset + 2 > length_) return entries;
        uint16_t count = u16(offset);
        for (uint16_t i = 0; i < count; ++i) {
            size_t at = offset + 2 + size_t(i) * 12;
            if (at + 12 > length_) break;
            Entry entry{u16(at), u16(at + 2), u32(at + 4), {}};
            size_t size = typeSize(entry.type) * entry.count;
            if (size == 0 && entry.count != 0) continue;
            size_t from = size <= 4 ? at + 8 : u32(at + 8);
            if (from + size > length_ || size > (16u << 20)) continue;
            entry.value.assign(data_ + from, data_ + from + size);
            entries.push_back(std::move(entry));
        }
        return entries;
    }

    uint32_t integer(const Entry &entry, size_t index = 0) const {
        const size_t at = index * typeSize(entry.type);
        if (at + typeSize(entry.type) > entry.value.size()) return 0;
        const uint8_t *p = entry.value.data() + at;
        if (entry.type == 3 || entry.type == 8) return value16(p);
        if (entry.type == 4 || entry.type == 9 || entry.type == 13) return value32(p);
        if (entry.type == 1 || entry.type == 7) return *p;
        return 0;
    }
    double real(const Entry &entry, size_t index = 0) const {
        if (entry.type == 5 || entry.type == 10) {
            const size_t at = index * 8;
            if (at + 8 > entry.value.size()) return 0;
            uint32_t n = value32(entry.value.data() + at), d = value32(entry.value.data() + at + 4);
            if (entry.type == 10) return d == 0 ? 0 : double(int32_t(n)) / double(int32_t(d));
            return d == 0 ? 0 : double(n) / double(d);
        }
        return integer(entry, index);
    }
    static std::string text(const Entry &entry) {
        if (entry.type != 2 && entry.type != 7) return {};
        std::string s(entry.value.begin(), entry.value.end());
        s = s.substr(0, s.find('\0'));
        size_t a = s.find_first_not_of(" \t\r\n"), b = s.find_last_not_of(" \t\r\n");
        return a == std::string::npos ? std::string() : s.substr(a, b - a + 1);
    }

private:
    void check(size_t at, size_t size) const {
        if (at + size > length_) throw Failure("truncated Exif record");
    }
    uint16_t value16(const uint8_t *p) const {
        return little_ ? uint16_t(p[0] | p[1] << 8) : uint16_t(p[0] << 8 | p[1]);
    }
    uint32_t value32(const uint8_t *p) const {
        return little_ ? uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16
                             | uint32_t(p[3]) << 24
                       : uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8
                             | uint32_t(p[3]);
    }
    const uint8_t *data_;
    size_t length_;
    bool little_ = true;
};

const Entry *find(const std::vector<Entry> &entries, uint16_t tag) {
    for (const auto &entry : entries)
        if (entry.tag == tag) return &entry;
    return nullptr;
}

/// Writes directories in the source's byte order, so values copy across unchanged.
class Writer {
public:
    explicit Writer(bool little) : little_(little) {
        out_ = {uint8_t(little ? 'I' : 'M'), uint8_t(little ? 'I' : 'M'), 0, 0, 0, 0, 0, 0};
        put16(2, 42);
        put32(4, 8);
    }
    /// Appends a directory, its large values after it; returns the directory's offset. Pointer
    /// entries are patched afterwards with `patch`.
    uint32_t directory(const std::vector<Entry> &entries) {
        uint32_t start = uint32_t(out_.size());
        out_.resize(out_.size() + 2 + entries.size() * 12 + 4, 0);
        put16(start, uint16_t(entries.size()));
        for (size_t i = 0; i < entries.size(); ++i) {
            const Entry &entry = entries[i];
            size_t at = start + 2 + i * 12;
            put16(at, entry.tag);
            put16(at + 2, entry.type);
            put32(at + 4, entry.count);
            slots_[entry.tag] = at + 8;
            if (entry.value.size() <= 4) {
                std::memcpy(&out_[at + 8], entry.value.data(), entry.value.size());
            } else {
                if (out_.size() % 2) out_.push_back(0);
                put32(at + 8, uint32_t(out_.size()));
                out_.insert(out_.end(), entry.value.begin(), entry.value.end());
            }
        }
        if (out_.size() % 2) out_.push_back(0);
        return start;
    }
    void patch(uint16_t tag, uint32_t value) { put32(slots_.at(tag), value); }
    std::vector<uint8_t> take() { return std::move(out_); }

private:
    void put16(size_t at, uint16_t v) {
        out_[at] = little_ ? uint8_t(v) : uint8_t(v >> 8);
        out_[at + 1] = little_ ? uint8_t(v >> 8) : uint8_t(v);
    }
    void put32(size_t at, uint32_t v) {
        for (int i = 0; i < 4; ++i)
            out_[at + i] = uint8_t(v >> (little_ ? 8 * i : 8 * (3 - i)));
    }
    bool little_;
    std::vector<uint8_t> out_;
    std::map<uint16_t, size_t> slots_;
};

} // namespace

ExifFields parseExif(const uint8_t *data, size_t length, ffc_capture &capture) {
    ExifFields fields;
    Reader reader(data, length);
    auto first = reader.directory(reader.firstIFD());
    if (auto e = find(first, tagOrientation)) {
        int value = int(reader.integer(*e));
        fields.orientation = value >= 1 && value <= 8 ? value : 1;
    }
    fields.isDNG = find(first, tagDNGVersion) != nullptr;
    if (fields.isDNG) {
        // The main image's default crop, in its own directory (the first, or a SubIFD).
        std::vector<std::vector<Entry>> candidates{first};
        if (auto subIFDs = find(first, 0x014A))
            for (uint32_t i = 0; i < subIFDs->count; ++i)
                candidates.push_back(reader.directory(reader.integer(*subIFDs, i)));
        for (const auto &directory : candidates) {
            auto kind = find(directory, 0x00FE);
            auto origin = find(directory, 0xC61F), size = find(directory, 0xC620);
            if ((kind && reader.integer(*kind) != 0) || !size) continue;
            fields.crop = {origin ? reader.real(*origin, 0) : 0, origin ? reader.real(*origin, 1) : 0,
                           reader.real(*size, 0), reader.real(*size, 1)};
            break;
        }
    }
    if (auto e = find(first, tagMake)) copyString(capture.make, sizeof capture.make, Reader::text(*e));
    if (auto e = find(first, tagModel)) copyString(capture.model, sizeof capture.model, Reader::text(*e));
    if (auto pointer = find(first, tagExifIFD)) {
        auto exif = reader.directory(reader.integer(*pointer));
        if (auto e = find(exif, tagFNumber)) capture.f_number = float(reader.real(*e));
        if (auto e = find(exif, tagFocalLength)) capture.focal_length = float(reader.real(*e));
        if (auto e = find(exif, tagFocal35)) capture.focal_length_35mm = float(reader.real(*e));
        if (auto e = find(exif, tagFocalPlaneX)) capture.focal_plane_x_resolution = reader.real(*e);
        if (auto e = find(exif, tagFocalPlaneY)) capture.focal_plane_y_resolution = reader.real(*e);
        if (auto e = find(exif, tagFocalPlaneUnit)) capture.focal_plane_unit = int32_t(reader.integer(*e));
        if (auto e = find(exif, tagLensMake))
            copyString(capture.lens_make, sizeof capture.lens_make, Reader::text(*e));
        if (auto e = find(exif, tagLensModel))
            copyString(capture.lens_model, sizeof capture.lens_model, Reader::text(*e));
    }
    return fields;
}

void keepExif(const uint8_t *data, size_t length, ffc_capture &capture) {
    // Kept already rewritten, location included (an export drops it unless asked), so a TIFF or
    // RAW file's whole structure is not held.
    std::vector<uint8_t> kept;
    try {
        kept = exportExif(data, length, true);
    } catch (const Failure &) {
        return;
    }
    if (kept.empty()) return;
    std::free(capture.exif);
    capture.exif = static_cast<uint8_t *>(std::malloc(kept.size()));
    if (!capture.exif) return;
    std::memcpy(capture.exif, kept.data(), kept.size());
    capture.exif_length = kept.size();
}

std::vector<uint8_t> exportExif(const uint8_t *data, size_t length, bool keepLocation) {
    if (!data || length == 0) return {};
    Reader reader(data, length);
    auto first = reader.directory(reader.firstIFD());
    // The first directory keeps what describes the picture's making, never how a file stores it.
    static const std::set<uint16_t> firstKept = {
        0x010E /* ImageDescription */, tagMake, tagModel, 0x011A /* XResolution */,
        0x011B /* YResolution */, 0x0128 /* ResolutionUnit */, 0x0131 /* Software */,
        0x0132 /* DateTime */, 0x013B /* Artist */, 0x8298 /* Copyright */,
    };
    static const std::set<uint16_t> exifDropped = {
        tagMakerNote, tagPixelX, tagPixelY, tagInteropIFD,
    };
    std::vector<Entry> top, exif, gps;
    for (auto &entry : first)
        if (firstKept.count(entry.tag)) top.push_back(entry);
    if (auto pointer = find(first, tagExifIFD)) {
        for (auto &entry : reader.directory(reader.integer(*pointer)))
            if (!exifDropped.count(entry.tag) && entry.value.size() <= 65536) exif.push_back(entry);
    }
    if (keepLocation) {
        if (auto pointer = find(first, tagGPSIFD)) gps = reader.directory(reader.integer(*pointer));
    }
    if (top.empty() && exif.empty() && gps.empty()) return {};
    const std::vector<uint8_t> zero(4, 0);
    if (!exif.empty()) top.push_back(Entry{tagExifIFD, 4, 1, zero});
    if (!gps.empty()) top.push_back(Entry{tagGPSIFD, 4, 1, zero});
    std::sort(top.begin(), top.end(), [](const Entry &a, const Entry &b) { return a.tag < b.tag; });

    Writer writer(reader.little());
    writer.directory(top);
    if (!exif.empty()) writer.patch(tagExifIFD, writer.directory(exif));
    if (!gps.empty()) writer.patch(tagGPSIFD, writer.directory(gps));
    return writer.take();
}

std::vector<std::pair<uint16_t, std::string>> exifText(const uint8_t *data, size_t length) {
    std::vector<std::pair<uint16_t, std::string>> text;
    if (!data || length == 0) return text;
    try {
        Reader reader(data, length);
        for (auto &entry : reader.directory(reader.firstIFD())) {
            if (entry.type != 2) continue;
            auto value = Reader::text(entry);
            if (!value.empty()) text.emplace_back(entry.tag, value);
        }
    } catch (const Failure &) {
    }
    return text;
}

} // namespace ffc

#endif

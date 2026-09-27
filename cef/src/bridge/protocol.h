// Messages between the renderer (React) and the browser process (engine host).
//
// A call carries the transport's own sequence number, the caller's message id, the method and its
// JSON parameters. Small messages travel as a CefListValue. A message with a binary payload
// travels in one shared-memory region instead, so pixels and file bytes are written once and
// never copied through the IPC channel:
//
//   [FramePrefix][header JSON][zero padding to kPayloadAlignment][payload bytes]
//
// The header JSON is {"seq", "id", "method", "params"} for a call, {"seq", "ok", "json"} for a
// reply and {"name", "json"} for an event, where "params" and "json" hold JSON text: the page
// parses every message the same way, whichever route it took.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>

namespace fotufilm::bridge {

// Renderer to browser.
inline constexpr char kCall[] = "fotufilm.call";
// Browser to renderer: the answer to one call.
inline constexpr char kReply[] = "fotufilm.reply";
// Browser to renderer: progress and host notifications, delivered as DOM events.
inline constexpr char kEvent[] = "fotufilm.event";

// List-value argument positions for messages without a payload.
enum CallArgument { kCallSeq = 0, kCallId, kCallMethod, kCallParams };
enum ReplyArgument { kReplySeq = 0, kReplyOk, kReplyJson };
enum EventArgument { kEventName = 0, kEventJson };

inline constexpr size_t kPayloadAlignment = 64;

// uint32 header length, uint32 zero, uint64 payload length.
struct FramePrefix {
  uint32_t header_length;
  uint32_t reserved;
  uint64_t payload_length;
};

inline size_t PayloadOffset(size_t header_length) {
  const size_t end = sizeof(FramePrefix) + header_length;
  return (end + kPayloadAlignment - 1) / kPayloadAlignment * kPayloadAlignment;
}

inline size_t FrameSize(size_t header_length, size_t payload_length) {
  return PayloadOffset(header_length) + payload_length;
}

// Writes the prefix and header; the caller writes the payload at PayloadOffset.
inline uint8_t* WriteFrameHeader(void* memory, std::string_view header,
                                 size_t payload_length) {
  const FramePrefix prefix{static_cast<uint32_t>(header.size()), 0,
                           payload_length};
  auto* bytes = static_cast<uint8_t*>(memory);
  std::memcpy(bytes, &prefix, sizeof prefix);
  std::memcpy(bytes + sizeof prefix, header.data(), header.size());
  const size_t offset = PayloadOffset(header.size());
  std::memset(bytes + sizeof prefix + header.size(), 0,
              offset - sizeof prefix - header.size());
  return bytes + offset;
}

struct FrameView {
  std::string_view header;
  const uint8_t* payload = nullptr;
  size_t payload_length = 0;
};

// False when the region is smaller than the lengths it claims. A region may be larger: shared
// memory is rounded up to whole pages.
inline bool ReadFrame(const void* memory, size_t size, FrameView& frame) {
  FramePrefix prefix{};
  if (!memory || size < sizeof prefix) return false;
  std::memcpy(&prefix, memory, sizeof prefix);
  const size_t offset = PayloadOffset(prefix.header_length);
  if (offset > size || prefix.payload_length > size - offset) return false;
  const auto* bytes = static_cast<const uint8_t*>(memory);
  frame.header = {reinterpret_cast<const char*>(bytes + sizeof prefix),
                  prefix.header_length};
  frame.payload = bytes + offset;
  frame.payload_length = static_cast<size_t>(prefix.payload_length);
  return true;
}

}  // namespace fotufilm::bridge

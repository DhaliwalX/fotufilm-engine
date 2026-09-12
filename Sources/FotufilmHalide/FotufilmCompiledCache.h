#pragma once

#include <Halide.h>
#include <cstring>
#include <memory>
#include <vector>

#if defined(__APPLE__) && defined(FOTUFILM_ENABLE_COMPILED_CACHE) \
    && !defined(FOTUFILM_HALIDE_AOT_GENERATOR)

#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <array>
#include <fcntl.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>

extern char **environ;
#endif

namespace fotufilm::compiled_cache {

// Bind the public parameter objects in a deliberate ABI order. Values are read at execution,
// so a kernel cache hit never reuses an image, LUT, seed, dimension, or edit setting.
struct Argument {
    Halide::Argument description;
    Halide::Parameter parameter;
    Argument(const Halide::ImageParam &value)
        : description(value), parameter(value.parameter()) {}
    template<typename T> Argument(const Halide::Param<T> &value)
        : description(value), parameter(value.parameter()) {}
};

#if defined(__APPLE__) && defined(FOTUFILM_ENABLE_COMPILED_CACHE) \
    && !defined(FOTUFILM_HALIDE_AOT_GENERATOR)

namespace detail {
namespace fs = std::filesystem;

struct FD {
    int value = -1;
    explicit FD(int value = -1) : value(value) {}
    FD(const FD &) = delete;
    FD &operator=(const FD &) = delete;
    ~FD() { if (value >= 0) close(value); }
};

struct SHA256 {
    CC_SHA256_CTX context;
    SHA256() { CC_SHA256_Init(&context); }
    void add(const void *bytes, size_t count) {
        const auto *p = static_cast<const unsigned char *>(bytes);
        while (count) {
            auto size = static_cast<CC_LONG>(std::min<size_t>(count, 1u << 20));
            CC_SHA256_Update(&context, p, size);
            p += size;
            count -= size;
        }
    }
    void add(const std::string &text) {
        uint64_t count = text.size();
        add(&count, sizeof(count));
        add(text.data(), text.size());
    }
    std::string finish() {
        unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(bytes, &context);
        const char *hex = "0123456789abcdef";
        std::string result;
        for (auto byte : bytes) {
            result += hex[byte >> 4];
            result += hex[byte & 15];
        }
        return result;
    }
};

struct Mapping {
    FD fd;
    struct stat before{};
    const void *bytes = MAP_FAILED;
    size_t size = 0;
    explicit Mapping(const fs::path &path) : fd(open(path.c_str(), O_RDONLY | O_CLOEXEC)) {
        if (fd.value < 0 || fstat(fd.value, &before) != 0 || !S_ISREG(before.st_mode)
            || before.st_size <= 0) throw std::runtime_error("cannot read cache dependency");
        size = static_cast<size_t>(before.st_size);
        bytes = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd.value, 0);
        if (bytes == MAP_FAILED) throw std::runtime_error("cannot map cache dependency");
    }
    ~Mapping() { if (bytes != MAP_FAILED) munmap(const_cast<void *>(bytes), size); }
    std::string digest() const {
        SHA256 hash;
        hash.add(bytes, size);
        struct stat after{};
        if (fstat(fd.value, &after) != 0 || before.st_size != after.st_size
            || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
            || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec
            || before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
            || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) {
            throw std::runtime_error("cache dependency changed during hashing");
        }
        return hash.finish();
    }
};

inline std::string file_digest(const fs::path &path) { return Mapping(path).digest(); }

inline std::array<unsigned char, 16> image_uuid(const void *bytes, size_t size) {
    if (size < sizeof(mach_header_64)) throw std::runtime_error("truncated executable identity");
    const auto *header = static_cast<const mach_header_64 *>(bytes);
    // Universal images require selecting a slice. Until supported, use the normal JIT.
    if (header->magic != MH_MAGIC_64 || header->sizeofcmds > size - sizeof(*header)) {
        throw std::runtime_error("unsupported executable identity");
    }
    const char *cursor = static_cast<const char *>(bytes) + sizeof(*header);
    const char *end = cursor + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (end - cursor < static_cast<ptrdiff_t>(sizeof(load_command))) break;
        const auto *command = reinterpret_cast<const load_command *>(cursor);
        if (command->cmdsize < sizeof(*command) || command->cmdsize > end - cursor) break;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(uuid_command)) {
            std::array<unsigned char, 16> uuid;
            std::memcpy(uuid.data(), reinterpret_cast<const uuid_command *>(cursor)->uuid, uuid.size());
            return uuid;
        }
        cursor += command->cmdsize;
    }
    throw std::runtime_error("executable has no UUID");
}

inline bool owned_file(const fs::path &path) {
    struct stat info{};
    return lstat(path.c_str(), &info) == 0 && S_ISREG(info.st_mode)
        && info.st_uid == geteuid() && info.st_nlink == 1
        && (info.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

inline void private_directory(const fs::path &path) {
    if (mkdir(path.c_str(), 0700) != 0 && errno != EEXIST) {
        throw std::runtime_error("cannot create kernel cache directory");
    }
    struct stat info{};
    if (lstat(path.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)
        || info.st_uid != geteuid() || (info.st_mode & 0077) != 0) {
        throw std::runtime_error("kernel cache directory must be private and owned");
    }
}

struct Lock {
    FD fd;
    explicit Lock(const fs::path &path)
        : fd(open(path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600)) {
        struct stat info{};
        if (fd.value < 0 || fstat(fd.value, &info) != 0 || !S_ISREG(info.st_mode)
            || info.st_uid != geteuid() || info.st_nlink != 1 || (info.st_mode & 0077)) {
            throw std::runtime_error("cannot open kernel cache lock");
        }
        while (flock(fd.value, LOCK_EX) != 0) {
            if (errno != EINTR) throw std::runtime_error("cannot lock kernel cache");
        }
    }
};

// posix_spawn is safe when another renderer has already created worker threads. Argument
// vectors preserve paths containing spaces without a shell or command substitution.
inline std::string command(std::vector<std::string> arguments) {
    int pipes[2];
    if (pipe(pipes) != 0) throw std::runtime_error("cannot capture compiler output");
    FD reader(pipes[0]), writer(pipes[1]);
    fcntl(reader.value, F_SETFD, FD_CLOEXEC);
    fcntl(writer.value, F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, writer.value, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, writer.value, STDERR_FILENO);
    std::vector<char *> argv;
    for (auto &argument : arguments) argv.push_back(argument.data());
    argv.push_back(nullptr);
    pid_t child = 0;
    int error = posix_spawn(&child, argv[0], &actions, nullptr, argv.data(), ::environ);
    posix_spawn_file_actions_destroy(&actions);
    close(writer.value);
    writer.value = -1;
    if (error) throw std::runtime_error("cannot start kernel linker");
    std::string output;
    char block[4096];
    for (;;) {
        ssize_t count = read(reader.value, block, sizeof(block));
        if (count > 0) {
            if (output.size() < 65536) output.append(block, static_cast<size_t>(count));
        } else if (count == 0) break;
        else if (errno != EINTR) break;
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) throw std::runtime_error("cannot wait for kernel linker");
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status)) {
        throw std::runtime_error("kernel compiler command failed");
    }
    while (!output.empty() && (output.back() == '\n' || output.back() == '\r')) output.pop_back();
    return output;
}

inline std::string image_digest(const void *symbol) {
    Dl_info info{};
    if (!dladdr(symbol, &info) || !info.dli_fname || !info.dli_fbase) {
        throw std::runtime_error("cannot identify kernel compiler image");
    }
    const auto *loaded = static_cast<const mach_header_64 *>(info.dli_fbase);
    Mapping file(info.dli_fname);
    // A build can replace the executable while an older test process is still running. Never
    // give its old kernel the new executable's digest; compare the loaded and on-disk UUIDs.
    if (loaded->magic != MH_MAGIC_64
        || image_uuid(loaded, sizeof(*loaded) + loaded->sizeofcmds)
            != image_uuid(file.bytes, file.size)) {
        throw std::runtime_error("loaded executable differs from its file");
    }
    return file.digest();
}

struct Store {
    fs::path root;
    std::string compiler, sdk;
    std::string identity;
    Store() {
        const char *setting = getenv("FOTUFILM_COMPILED_CACHE");
        if (setting && std::string(setting) == "0") throw std::runtime_error("disabled");
        const char *directory = getenv("FOTUFILM_COMPILED_CACHE_DIRECTORY");
        if (directory && *directory) {
            root = fs::absolute(directory);
        } else {
            size_t size = confstr(_CS_DARWIN_USER_CACHE_DIR, nullptr, 0);
            if (!size) throw std::runtime_error("no user cache directory");
            std::vector<char> path(size);
            if (!confstr(_CS_DARWIN_USER_CACHE_DIR, path.data(), size)) {
                throw std::runtime_error("no user cache directory");
            }
            root = fs::path(path.data()) / "fotufilm-compiled-kernels-v1";
        }
        private_directory(root);
        compiler = command({"/usr/bin/xcrun", "--sdk", "macosx", "--find", "clang++"});
        sdk = command({"/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"});
        auto linker = command({"/usr/bin/xcrun", "--sdk", "macosx", "--find", "ld"});
        SHA256 hash;
        hash.add("Fotufilm compiled kernel ABI 1");
        // Hash the complete containing image: this covers source, headers, compiler flags,
        // constants, and every ABI change, including builds made outside this checkout.
        hash.add(image_digest(reinterpret_cast<const void *>(&image_digest)));
        hash.add(image_digest(reinterpret_cast<const void *>(&Halide::get_host_target)));
        hash.add(file_digest(compiler));
        hash.add(file_digest(linker));
        hash.add(sdk);
        hash.add(command({"/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"}));
        std::vector<std::string> environment;
        for (char **item = ::environ; item && *item; ++item) {
            std::string value(*item);
            if (value.rfind("HL_", 0) == 0 || value.rfind("FOTUFILM_", 0) == 0) {
                if (value.rfind("FOTUFILM_COMPILED_CACHE", 0) != 0) environment.push_back(value);
            }
        }
        std::sort(environment.begin(), environment.end());
        for (const auto &value : environment) hash.add(value);
        identity = hash.finish();
        root /= identity;
        private_directory(root);
    }
};

inline Store *store() {
    // Failed setup stays disabled for this process; a broken cache must not add work per frame.
    static Store *value = []() -> Store * {
        try { return new Store; } catch (...) { return nullptr; }
    }();
    return value;
}

struct TemporaryDirectory {
    fs::path path;
    explicit TemporaryDirectory(const fs::path &parent) {
        std::string pattern = (parent / "pending-XXXXXX").string();
        if (!mkdtemp(pattern.data())) throw std::runtime_error("cannot stage compiled kernel");
        path = pattern;
    }
    ~TemporaryDirectory() { std::error_code error; fs::remove_all(path, error); }
};

inline bool verified(const fs::path &library) {
    auto stamp = library.string() + ".sha256";
    if (!owned_file(library) || !owned_file(stamp)) return false;
    // A damaged stamp is a miss, including an oversized file; never read it without a bound.
    std::ifstream stream(stamp, std::ios::binary);
    char content[66];
    stream.read(content, sizeof(content));
    if (stream.gcount() != 65 || content[64] != '\n') return false;
    try {
        return file_digest(library) == std::string(content, 64);
    } catch (...) {
        return false;
    }
}

inline void publish(const fs::path &temporary, const fs::path &library) {
    auto stamp = temporary.string() + ".sha256";
    {
        std::ofstream stream(stamp, std::ios::binary);
        stream << file_digest(temporary) << '\n';
        stream.close();
        if (!stream) throw std::runtime_error("cannot stamp compiled kernel");
    }
    if (chmod(temporary.c_str(), 0600) || chmod(stamp.c_str(), 0600)) {
        throw std::runtime_error("cannot protect compiled kernel");
    }
    fs::rename(temporary, library);
    fs::rename(stamp, library.string() + ".sha256");
}

struct Loaded {
    using Call = int (*)(void **);
    void *handle = nullptr;
    Call call = nullptr;
    const halide_device_interface_t *device = nullptr;
};

inline void validate_metadata(void *handle, const std::vector<Argument> &arguments,
                              const Halide::Target &target) {
    using Metadata = const halide_filter_metadata_t *(*)();
    auto get = reinterpret_cast<Metadata>(dlsym(handle, "fotufilm_cached_kernel_metadata"));
    if (!get) throw std::runtime_error("compiled kernel has no argument metadata");
    const auto *metadata = get();
    if (metadata->version != halide_filter_metadata_t::VERSION
        || metadata->num_arguments != static_cast<int>(arguments.size() + 1)
        || metadata->target != target.to_string()) {
        throw std::runtime_error("compiled kernel metadata mismatch");
    }
    // Metadata order is not an ABI promise. The ordered signature is already part of the key.
    std::map<std::string, const halide_filter_argument_t *> named;
    for (int i = 0; i < metadata->num_arguments; ++i) {
        if (!named.emplace(metadata->arguments[i].name, &metadata->arguments[i]).second) {
            throw std::runtime_error("duplicate compiled argument");
        }
    }
    for (const auto &argument : arguments) {
        auto found = named.find(argument.description.name);
        if (found == named.end()) throw std::runtime_error("missing compiled argument");
        const auto &actual = *found->second;
        if (actual.kind != static_cast<int>(argument.description.kind)
            || actual.dimensions != argument.description.dimensions
            || Halide::Type(actual.type) != argument.description.type) {
            throw std::runtime_error("compiled argument type mismatch");
        }
    }
}

inline std::shared_ptr<Loaded> load(Halide::Pipeline &pipeline, const std::string &variant,
                                   const std::vector<Argument> &arguments, Halide::Target target) {
    Store *cache = store();
    if (!cache) return nullptr;
    if (target.os != Halide::Target::OSX || target.bits != 64) return nullptr;
    target.set_feature(Halide::Target::JIT, false);
    target.set_feature(Halide::Target::UserContext, false);
    target.set_feature(Halide::Target::NoRuntime);
    SHA256 key;
    key.add(variant);
    key.add(target.to_string());
    std::vector<Halide::Argument> descriptions;
    for (const auto &argument : arguments) {
        descriptions.push_back(argument.description);
        const auto &a = argument.description;
        key.add(a.name);
        key.add(std::to_string(a.kind));
        key.add(std::to_string(a.dimensions));
        key.add(std::to_string(a.type.code()) + ":" + std::to_string(a.type.bits())
                + ":" + std::to_string(a.type.lanes()));
    }
    const std::string digest = key.finish();
    static std::mutex mutex;
    static auto *loaded = new std::map<std::string, std::shared_ptr<Loaded>>;
    std::lock_guard<std::mutex> guard(mutex);
    auto found = loaded->find(digest);
    if (found != loaded->end()) return found->second;
    Lock lock(cache->root / (digest + ".lock"));

    // One runtime provides both CPU allocation and Metal device interfaces. A buffer is always
    // wrapped/uploaded using the same runtime that will execute its compiled kernel.
    auto runtimeTarget = target.without_feature(Halide::Target::NoRuntime)
        .without_feature(Halide::Target::StrictFloat).with_feature(Halide::Target::Metal);
    SHA256 runtimeKey;
    runtimeKey.add(runtimeTarget.to_string());
    fs::path runtime = cache->root / ("runtime-" + runtimeKey.finish() + ".dylib");
    {
        Lock runtimeLock(runtime.string() + ".lock");
        if (!verified(runtime)) {
            TemporaryDirectory temporary(cache->root);
            auto object = temporary.path / "runtime.o";
            auto library = temporary.path / "runtime.dylib";
            Halide::compile_standalone_runtime(object.string(), runtimeTarget);
            command({cache->compiler, "-dynamiclib", "-isysroot", cache->sdk,
                     object.string(), "-Wl,-install_name," + runtime.string(),
                     "-framework", "Metal", "-framework", "Foundation", "-o", library.string()});
            publish(library, runtime);
        }
    }
    // Halide uses coalesced weak runtime symbols; RTLD_GLOBAL makes them available to every
    // cached module. Handles stay loaded for the lifetime of device buffers and worker threads.
    void *runtimeHandle = dlopen(runtime.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!runtimeHandle) throw std::runtime_error("cannot load compiled runtime");
    fs::path library = cache->root / (digest + ".dylib");
    if (!verified(library)) {
        TemporaryDirectory temporary(cache->root);
        auto object = temporary.path / "kernel.o";
        auto output = temporary.path / "kernel.dylib";
        pipeline.compile_to_object(object.string(), descriptions, "fotufilm_cached_kernel", target);
        command({cache->compiler, "-dynamiclib", "-isysroot", cache->sdk,
                 object.string(), runtime.string(), "-o", output.string()});
        publish(output, library);
    }
    auto result = std::make_shared<Loaded>();
    result->handle = dlopen(library.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!result->handle) throw std::runtime_error("cannot load compiled kernel");
    validate_metadata(result->handle, arguments, target);
    result->call = reinterpret_cast<Loaded::Call>(dlsym(result->handle, "fotufilm_cached_kernel_argv"));
    if (!result->call) throw std::runtime_error("compiled kernel has no entry point");
    if (target.has_feature(Halide::Target::Metal)) {
        using Device = const halide_device_interface_t *(*)();
        auto get = reinterpret_cast<Device>(dlsym(runtimeHandle, "halide_metal_device_interface"));
        if (!get || !(result->device = get())) throw std::runtime_error("compiled runtime has no Metal interface");
    }
    loaded->emplace(digest, result);
    return result;
}
} // namespace detail
#endif

class Pipeline {
    std::vector<Argument> arguments_;
#if defined(__APPLE__) && defined(FOTUFILM_ENABLE_COMPILED_CACHE) \
    && !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    std::shared_ptr<detail::Loaded> loaded_;
#endif
public:
    bool prepare(Halide::Pipeline &pipeline, const std::string &variant,
                 std::vector<Argument> arguments, const Halide::Target &target) {
#if defined(__APPLE__) && defined(FOTUFILM_ENABLE_COMPILED_CACHE) \
    && !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
        loaded_.reset();
        arguments_.clear();
        try {
            for (const auto &argument : arguments) {
                const auto &type = argument.description.type;
                if (!argument.description.is_buffer() && type != Halide::Float(32)
                    && type != Halide::Int(32) && type != Halide::UInt(32)) return false;
            }
            auto loaded = detail::load(pipeline, variant, arguments, target);
            if (!loaded) return false;
            arguments_ = std::move(arguments);
            loaded_ = std::move(loaded);
            return true;
        } catch (...) {
            return false;
        }
#else
        return false;
#endif
    }
    explicit operator bool() const {
#if defined(__APPLE__) && defined(FOTUFILM_ENABLE_COMPILED_CACHE) \
    && !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
        return bool(loaded_);
#else
        return false;
#endif
    }
    const halide_device_interface_t *device_interface() const {
#if defined(__APPLE__) && defined(FOTUFILM_ENABLE_COMPILED_CACHE) \
    && !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
        return loaded_ ? loaded_->device : nullptr;
#else
        return nullptr;
#endif
    }
    template<typename Pixel> void realize(Halide::Buffer<Pixel> &output) const {
#if defined(__APPLE__) && defined(FOTUFILM_ENABLE_COMPILED_CACHE) \
    && !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
        if (!loaded_) throw std::runtime_error("compiled pipeline is not prepared");
        std::vector<uint64_t> scalars(arguments_.size());
        std::vector<Halide::Buffer<>> buffers(arguments_.size());
        std::vector<void *> argv;
        for (size_t i = 0; i < arguments_.size(); ++i) {
            const auto &argument = arguments_[i];
            if (argument.description.is_buffer()) {
                buffers[i] = argument.parameter.buffer();
                argv.push_back(buffers[i].raw_buffer());
            } else {
                auto type = argument.parameter.type();
                if (type == Halide::Float(32)) {
                    float value = argument.parameter.scalar<float>();
                    std::memcpy(&scalars[i], &value, sizeof(value));
                } else if (type == Halide::Int(32)) {
                    int32_t value = argument.parameter.scalar<int32_t>();
                    std::memcpy(&scalars[i], &value, sizeof(value));
                } else if (type == Halide::UInt(32)) {
                    uint32_t value = argument.parameter.scalar<uint32_t>();
                    std::memcpy(&scalars[i], &value, sizeof(value));
                } else {
                    throw std::runtime_error("unsupported compiled scalar type");
                }
                argv.push_back(&scalars[i]);
            }
        }
        argv.push_back(output.raw_buffer());
        int status = loaded_->call(argv.data());
        if (status) throw Halide::RuntimeError("Compiled kernel failed: " + std::to_string(status));
#else
        throw Halide::RuntimeError("Compiled pipeline is not prepared");
#endif
    }
};
} // namespace fotufilm::compiled_cache

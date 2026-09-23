# Software Vulkan checks Linux ABI/runtime portability. It does not qualify a hardware GPU.
FROM swift:6.2
RUN apt-get update && apt-get install -y --no-install-recommends \
    libvulkan1 mesa-vulkan-drivers vulkan-tools vulkan-validationlayers python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /src

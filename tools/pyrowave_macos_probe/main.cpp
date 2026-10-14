// Exercise the vendored codec independently of capture and streaming. The CPU
// buffer API uploads the source to the GPU; encoding and decoding still use
// Vulkan compute through MoltenVK. This is not a CPU encoder fallback.
#include <volk.h>
#include <pyrowave.h>

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>

namespace {
  void report_device(pyrowave_device device) {
    VkPhysicalDevice gpu = VK_NULL_HANDLE;
    pyrowave_device_get_vk_device_handles(device, nullptr, &gpu, nullptr);
    VkPhysicalDeviceSubgroupSizeControlProperties size {
      VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_SIZE_CONTROL_PROPERTIES};
    VkPhysicalDeviceSubgroupProperties subgroup {
      VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES, &size};
    VkPhysicalDeviceProperties2 props {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &subgroup};
    volk::vkGetPhysicalDeviceProperties2(gpu, &props);
    VkPhysicalDeviceSubgroupSizeControlFeatures size_features {
      VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_SIZE_CONTROL_FEATURES};
    VkPhysicalDevice8BitStorageFeatures storage {
      VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_8BIT_STORAGE_FEATURES, &size_features};
    VkPhysicalDeviceFeatures2 features {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &storage};
    volk::vkGetPhysicalDeviceFeatures2(gpu, &features);
    std::cout << "GPU: " << props.properties.deviceName
              << "\nSubgroup: size=" << subgroup.subgroupSize
              << " range=" << size.minSubgroupSize << '-' << size.maxSubgroupSize
              << " operations=0x" << std::hex << subgroup.supportedOperations << std::dec
              << " requiredSizeStages=0x" << std::hex << size.requiredSubgroupSizeStages << std::dec
              << "\nshaderInt16=" << features.features.shaderInt16
              << " storageBuffer8BitAccess=" << storage.storageBuffer8BitAccess
              << " subgroupSizeControl=" << size_features.subgroupSizeControl
              << " computeFullSubgroups=" << size_features.computeFullSubgroups << '\n';
    constexpr VkSubgroupFeatureFlags required =
      VK_SUBGROUP_FEATURE_BASIC_BIT | VK_SUBGROUP_FEATURE_VOTE_BIT |
      VK_SUBGROUP_FEATURE_ARITHMETIC_BIT | VK_SUBGROUP_FEATURE_BALLOT_BIT |
      VK_SUBGROUP_FEATURE_SHUFFLE_BIT | VK_SUBGROUP_FEATURE_SHUFFLE_RELATIVE_BIT |
      VK_SUBGROUP_FEATURE_CLUSTERED_BIT;
    if (const auto missing = required & ~subgroup.supportedOperations) {
      std::cout << "Missing subgroup operations: 0x" << std::hex << missing << std::dec
                << " (CLUSTERED=0x40)\n";
    }
    std::cout.flush();
  }

  void check(pyrowave_result result, const char *operation) {
    if (result != PYROWAVE_SUCCESS) {
      throw std::runtime_error(std::string(operation) + " failed: " + std::to_string(result));
    }
  }

  struct frame {
    std::array<std::vector<unsigned char>, 3> planes {
      std::vector<unsigned char>(128 * 128),
      std::vector<unsigned char>(64 * 64, 128),
      std::vector<unsigned char>(64 * 64, 128)
    };

    pyrowave_cpu_buffer buffer() {
      pyrowave_cpu_buffer result {};
      result.width = result.height = 128;
      result.format = PYROWAVE_CPU_BUFFER_FORMAT_YUV420P;
      for (unsigned i = 0; i < 3; ++i) {
        result.data[i] = planes[i].data();
        result.row_stride_in_bytes[i] = i == 0 ? 128 : 64;
        result.plane_size_in_bytes[i] = planes[i].size();
      }
      return result;
    }
  };
}

int main(int argc, char **argv) {
  if (argc > 2) {
    std::cerr << "Usage: pyrowave_macos_probe [absolute path to libMoltenVK.dylib]\n";
    return 2;
  }
  if (argc == 2) {
    setenv("GRANITE_VULKAN_LIBRARY", argv[1], 1);
  }

  pyrowave_device device = nullptr;
  const auto result = pyrowave_create_default_device(&device);
  if (result != PYROWAVE_SUCCESS) {
    std::cerr << "SKIP: Vulkan device unavailable (" << result
              << "). Set GRANITE_VULKAN_LIBRARY to libMoltenVK.dylib.\n";
    return 77;
  }
  std::unique_ptr<std::remove_pointer_t<pyrowave_device>, decltype(&pyrowave_device_destroy)>
    device_guard(device, pyrowave_device_destroy);

  try {
    report_device(device);
    pyrowave_encoder encoder = nullptr;
    pyrowave_encoder_create_info info {device, 128, 128, PYROWAVE_CHROMA_SUBSAMPLING_420};
    check(pyrowave_encoder_create(&info, &encoder), "encoder creation");
    std::unique_ptr<std::remove_pointer_t<pyrowave_encoder>, decltype(&pyrowave_encoder_destroy)>
      encoder_guard(encoder, pyrowave_encoder_destroy);

    frame source;
    for (unsigned y = 0; y < 128; ++y) {
      for (unsigned x = 0; x < 128; ++x) {
        source.planes[0][y * 128 + x] = 32 + (x + y) % 192;
      }
    }
    auto input = source.buffer();
    pyrowave_rate_control rate {65536};
    check(pyrowave_encoder_encode_cpu_synchronous(encoder, &input, &rate), "GPU encode");

    constexpr std::size_t boundary = 1200;
    std::size_t count = 0;
    check(pyrowave_encoder_compute_num_packets(encoder, boundary, &count), "packet count/readback");
    if (!count || count > 1024) throw std::runtime_error("invalid packet count");
    std::vector<pyrowave_packet> packets(count);
    std::vector<unsigned char> bitstream(count * boundary);
    check(pyrowave_encoder_packetize(encoder, packets.data(), boundary, &count,
                                    bitstream.data(), bitstream.size()), "packetization");
    if (!count || count > packets.size()) throw std::runtime_error("invalid packetization result");

    pyrowave_decoder decoder = nullptr;
    pyrowave_decoder_create_info decoder_info {};
    decoder_info.device = device;
    decoder_info.width = decoder_info.height = 128;
    decoder_info.chroma = PYROWAVE_CHROMA_SUBSAMPLING_420;
    check(pyrowave_decoder_create(&decoder_info, &decoder), "decoder creation");
    std::unique_ptr<std::remove_pointer_t<pyrowave_decoder>, decltype(&pyrowave_decoder_destroy)>
      decoder_guard(decoder, pyrowave_decoder_destroy);
    for (std::size_t i = 0; i < count; ++i) {
      const auto &packet = packets[i];
      if (packet.offset > bitstream.size() || packet.size > bitstream.size() - packet.offset)
        throw std::runtime_error("invalid packet bounds");
      check(pyrowave_decoder_push_packet(decoder, bitstream.data() + packet.offset, packet.size), "decoder packet");
    }
    if (!pyrowave_decoder_decode_is_ready(decoder, false)) throw std::runtime_error("incomplete frame");
    frame decoded;
    auto output = decoded.buffer();
    check(pyrowave_decoder_decode_cpu_buffer_synchronous(decoder, &output), "GPU decode/readback");
    double error = 0;
    std::size_t samples = 0;
    for (unsigned plane = 0; plane < 3; ++plane) {
      for (std::size_t i = 0; i < source.planes[plane].size(); ++i) {
        error += std::abs(int(source.planes[plane][i]) - int(decoded.planes[plane][i]));
        ++samples;
      }
    }
    error /= samples;
    if (error > 8) throw std::runtime_error("decoded frame differs from input: MAE=" + std::to_string(error));
    std::cout << "PASS: PyroWave GPU encode, packetize, decode; " << count
              << " packets; mean absolute error=" << error << '\n';
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}

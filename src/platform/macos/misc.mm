/**
 * @file src/platform/macos/misc.mm
 * @brief Miscellaneous definitions for macOS platform.
 */

// Required for IPV6_PKTINFO with Darwin headers
#ifndef __APPLE_USE_RFC_3542  // NOLINT(bugprone-reserved-identifier)
  #define __APPLE_USE_RFC_3542 1
#endif

// standard includes
#include <fcntl.h>
#include <ifaddrs.h>

// platform includes
#include <arpa/inet.h>
#include <dlfcn.h>
#include <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <mach-o/dyld.h>
#include <net/if_dl.h>
#include <pwd.h>
#include <sys/qos.h>

// lib includes
#include <boost/asio/ip/address.hpp>
#include <boost/asio/ip/host_name.hpp>
#include <boost/asio/system_executor.hpp>
#include <boost/program_options/parsers.hpp>

// local includes
#include "misc.h"
#include "src/platform/common_services.h"
#include "src/boost_process_shim.h"
#include "src/entry_handler.h"
#include "src/logging.h"
#include "src/platform/common.h"

using namespace std::literals;
namespace fs = std::filesystem;
namespace bp = boost_process_shim;
namespace v2 = boost::process::v2;

// Finder sends a reopen Apple event even for an LSUIElement app that
// already has a running instance. Keep this handler independent of the tray
// library's application delegate, which owns the status-menu callbacks.
@interface VibepolloOpenHandler: NSObject
@property(nonatomic, assign) BOOL configurationReady;
@property(nonatomic, assign) BOOL openRequested;
- (void)handleOpen:(NSAppleEventDescriptor *)event withReply:(NSAppleEventDescriptor *)reply;
- (void)configurationDidBecomeReady;
@end

@implementation VibepolloOpenHandler
- (void)handleOpen:(NSAppleEventDescriptor *)event withReply:(NSAppleEventDescriptor *)reply {
  if (self.configurationReady) {
    BOOST_LOG(info) << "Opening configuration UI from Finder";
    launch_ui();
  } else {
    self.openRequested = YES;
  }
}

- (void)configurationDidBecomeReady {
  self.configurationReady = YES;
  if (self.openRequested) {
    self.openRequested = NO;
    BOOST_LOG(info) << "Opening configuration UI after startup";
    launch_ui();
  }
}
@end

static VibepolloOpenHandler *app_open_handler;

namespace platf {

  bool prepare_app() {
    @autoreleasepool {
      NSBundle *bundle = [NSBundle mainBundle];
      if ([bundle.bundlePath.pathExtension isEqualToString:@"app"]) {
        std::error_code error;
        fs::current_path(fs::path(bundle.executablePath.fileSystemRepresentation).parent_path(), error);
        if (error) {
          std::fprintf(stderr, "Vibepollo: cannot resolve app resources: %s\n", error.message().c_str());
          return false;
        }
      }
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      app_open_handler = [[VibepolloOpenHandler alloc] init];
      app_open_handler.openRequested = [bundle.bundlePath.pathExtension isEqualToString:@"app"];
      [NSApp finishLaunching];
    }
    return true;
  }

  void configuration_ui_ready() {
    // The HTTPS listener calls this from its worker thread. Wait until it is
    // listening before honoring Finder requests, then open on AppKit's thread.
    dispatch_async(dispatch_get_main_queue(), ^{
      // AppKit sets up its own Apple-event handlers during launch. Register
      // after that setup (and the tray delegate) so reopening reaches us.
      [[NSAppleEventManager sharedAppleEventManager]
        setEventHandler:app_open_handler andSelector:@selector(handleOpen:withReply:)
        forEventClass:kCoreEventClass andEventID:kAEReopenApplication];
      [app_open_handler configurationDidBecomeReady];
    });
  }

  void poll_app_events() {
    @autoreleasepool {
      NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                        untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                           inMode:NSDefaultRunLoopMode
                                          dequeue:YES];
      if (event) {
        [NSApp sendEvent:event];
      }
      [NSApp updateWindows];
    }
  }

  // Return whether screen capture is allowed for this process.
  bool is_screen_capture_allowed() {
    // Permission may be granted or revoked while the web UI remains open.
    return CGPreflightScreenCaptureAccess();
  }

  std::unique_ptr<deinit_t> init() {
    if (!is_screen_capture_allowed()) {
      BOOST_LOG(error) << "No screen capture permission!"sv;
      BOOST_LOG(error) << "Enable Vibepollo in System Settings -> Privacy & Security -> Screen & System Audio Recording"sv;
      CGRequestScreenCaptureAccess();
      return nullptr;
    }
    return std::make_unique<deinit_t>();
  }

  fs::path appdata() {
    const char *homedir;
    if ((homedir = getenv("HOME")) == nullptr) {
      homedir = getpwuid(geteuid())->pw_dir;
    }

    return services::home_config_root(std::optional<fs::path> {fs::path {homedir}}, fs::path {homedir});
  }

  using ifaddr_t = util::safe_ptr<ifaddrs, freeifaddrs>;

  ifaddr_t get_ifaddrs() {
    ifaddrs *p {nullptr};

    getifaddrs(&p);

    return ifaddr_t {p};
  }

  std::string from_sockaddr(const sockaddr *const ip_addr) {
    char data[INET6_ADDRSTRLEN] = {};

    auto family = ip_addr->sa_family;
    if (family == AF_INET6) {
      inet_ntop(AF_INET6, &((sockaddr_in6 *) ip_addr)->sin6_addr, data, INET6_ADDRSTRLEN);
    } else if (family == AF_INET) {
      inet_ntop(AF_INET, &((sockaddr_in *) ip_addr)->sin_addr, data, INET_ADDRSTRLEN);
    }

    return std::string {data};
  }

  std::pair<std::uint16_t, std::string> from_sockaddr_ex(const sockaddr *const ip_addr) {
    char data[INET6_ADDRSTRLEN] = {};

    auto family = ip_addr->sa_family;
    std::uint16_t port = 0;
    if (family == AF_INET6) {
      inet_ntop(AF_INET6, &((sockaddr_in6 *) ip_addr)->sin6_addr, data, INET6_ADDRSTRLEN);
      port = ((sockaddr_in6 *) ip_addr)->sin6_port;
    } else if (family == AF_INET) {
      inet_ntop(AF_INET, &((sockaddr_in *) ip_addr)->sin_addr, data, INET_ADDRSTRLEN);
      port = ((sockaddr_in *) ip_addr)->sin_port;
    }

    return {port, std::string {data}};
  }

  std::string get_mac_address(const std::string_view &address) {
    auto ifaddrs = get_ifaddrs();

    for (auto pos = ifaddrs.get(); pos != nullptr; pos = pos->ifa_next) {
      if (pos->ifa_addr && address == from_sockaddr(pos->ifa_addr)) {
        BOOST_LOG(verbose) << "Looking for MAC of "sv << pos->ifa_name;

        struct ifaddrs *ifap, *ifaptr;
        unsigned char *ptr;
        std::string mac_address;

        if (getifaddrs(&ifap) == 0) {
          for (ifaptr = ifap; ifaptr != nullptr; ifaptr = (ifaptr)->ifa_next) {
            if (!strcmp((ifaptr)->ifa_name, pos->ifa_name) && (((ifaptr)->ifa_addr)->sa_family == AF_LINK)) {
              ptr = (unsigned char *) LLADDR((struct sockaddr_dl *) (ifaptr)->ifa_addr);
              char buff[100];

              snprintf(buff, sizeof(buff), "%02x:%02x:%02x:%02x:%02x:%02x", *ptr, *(ptr + 1), *(ptr + 2), *(ptr + 3), *(ptr + 4), *(ptr + 5));
              mac_address = buff;
              break;
            }
          }

          freeifaddrs(ifap);

          if (ifaptr != nullptr) {
            BOOST_LOG(verbose) << "Found MAC of "sv << pos->ifa_name << ": "sv << mac_address;
            return mac_address;
          }
        }
      }
    }

    BOOST_LOG(warning) << "Unable to find MAC address for "sv << address;
    return "00:00:00:00:00:00"s;
  }

  // TODO: return actual IP
  std::string get_local_ip_for_gateway() {
    return "";
  }

  bp::child run_command(bool elevated, bool interactive, const std::string &cmd, boost::filesystem::path &working_dir, const bp::environment &env, FILE *file, std::error_code &ec, bp::group *group) {
    (void) elevated;
    (void) interactive;
    ec.clear();

    std::vector<std::string> parts;
    try {
      parts = boost::program_options::split_unix(cmd);
    } catch (...) {
    }

    if (parts.empty()) {
      ec = std::make_error_code(std::errc::invalid_argument);
      return bp::child();
    }

    auto exe_path = v2::filesystem::path(parts.front());
    // Only PATH-search when there's no directory component (e.g., "foo" not "./foo" or "../foo")
    if (!exe_path.is_absolute() && exe_path.parent_path().empty()) {
      exe_path = v2::environment::find_executable(exe_path);
    }

    if (exe_path.empty()) {
      ec = std::make_error_code(std::errc::no_such_file_or_directory);
      return bp::child();
    }

    std::vector<std::string> args;
    if (parts.size() > 1) {
      args.assign(parts.begin() + 1, parts.end());
    }

    v2::process_stdio stdio {};
    stdio.in = nullptr;
    if (file) {
      stdio.out = file;
      stdio.err = file;
    } else {
      stdio.out = nullptr;
      stdio.err = nullptr;
    }

    auto env_init = env.to_process_environment();
    boost::asio::system_executor exec;

    try {
      if (group) {
        if (!working_dir.empty()) {
          auto start = v2::process_start_dir(v2::filesystem::path(working_dir.string()));
          auto proc = v2::process(exec, exe_path, args, start, stdio, env_init, bp::detail::posix_group_initer {group});
          return bp::child(std::move(proc));
        }
        auto proc = v2::process(exec, exe_path, args, stdio, env_init, bp::detail::posix_group_initer {group});
        return bp::child(std::move(proc));
      }

      if (!working_dir.empty()) {
        auto start = v2::process_start_dir(v2::filesystem::path(working_dir.string()));
        auto proc = v2::process(exec, exe_path, args, start, stdio, env_init);
        return bp::child(std::move(proc));
      }
      auto proc = v2::process(exec, exe_path, args, stdio, env_init);
      return bp::child(std::move(proc));
    } catch (const std::system_error &e) {
      ec = e.code();
      return bp::child();
    } catch (...) {
      ec = std::make_error_code(std::errc::invalid_argument);
      return bp::child();
    }
  }

  /**
   * @brief Open a url in the default web browser.
   * @param url The url to open.
   */
  void open_url(const std::string &url) {
    const auto url_copy = url;
    dispatch_async(dispatch_get_main_queue(), ^{
      @autoreleasepool {
        NSURL *target = [NSURL URLWithString:[NSString stringWithUTF8String:url_copy.c_str()]];
        if (target && [[NSWorkspace sharedWorkspace] openURL:target]) {
          BOOST_LOG(info) << "Opened url [" << url_copy << "]";
        } else {
          BOOST_LOG(warning) << "Couldn't open url [" << url_copy << "]";
        }
      }
    });
  }

  void adjust_thread_priority(thread_priority_e priority) {
    qos_class_t mac_priority;

    switch (priority) {
      case thread_priority_e::low:
        mac_priority = QOS_CLASS_UTILITY;
        break;
      case thread_priority_e::normal:
        mac_priority = QOS_CLASS_DEFAULT;
        break;
      case thread_priority_e::high:
        mac_priority = QOS_CLASS_USER_INITIATED;
        break;
      case thread_priority_e::critical:
        mac_priority = QOS_CLASS_USER_INTERACTIVE;
        break;
      default:
        BOOST_LOG(error) << "Unknown thread priority: "sv << (int) priority;
        return;
    }

    // https://github.com/apple/darwin-libpthread/blob/main/include/sys/qos.h
    pthread_set_qos_class_self_np(mac_priority, 0);
  }

  void set_thread_name(const std::string &name) {
    pthread_setname_np(name.c_str());
  }

  void enable_mouse_keys() {
    // Unimplemented
  }

  void streaming_will_start() {
    // Nothing to do
  }

  void streaming_will_stop() {
    // Nothing to do
  }

  void restart_on_exit() {
    char executable[2048];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) < 0) {
      BOOST_LOG(fatal) << "NSGetExecutablePath() failed: "sv << errno;
      return;
    }

    // ASIO doesn't use O_CLOEXEC, so we have to close all fds ourselves
    int openmax = (int) sysconf(_SC_OPEN_MAX);
    for (int fd = STDERR_FILENO + 1; fd < openmax; fd++) {
      close(fd);
    }

    // Re-exec ourselves with the same arguments
    if (execv(executable, lifetime::get_argv()) < 0) {
      BOOST_LOG(fatal) << "execv() failed: "sv << errno;
      return;
    }
  }

  void restart() {
    // Gracefully clean up and restart ourselves instead of exiting
    atexit(restart_on_exit);
    lifetime::exit_sunshine(0, true);
  }

  int set_env(const std::string &name, const std::string &value) {
    return services::process_environment().set(name, value);
  }

  int unset_env(const std::string &name) {
    return services::process_environment().unset(name);
  }

  bool request_process_group_exit(std::uintptr_t native_handle) {
    if (killpg((pid_t) native_handle, SIGTERM) == 0 || errno == ESRCH) {
      BOOST_LOG(debug) << "Successfully sent SIGTERM to process group: "sv << native_handle;
      return true;
    } else {
      BOOST_LOG(warning) << "Unable to send SIGTERM to process group ["sv << native_handle << "]: "sv << errno;
      return false;
    }
  }

  bool process_group_running(std::uintptr_t native_handle) {
    return waitpid(-((pid_t) native_handle), nullptr, WNOHANG) >= 0;
  }

  struct sockaddr_in to_sockaddr(boost::asio::ip::address_v4 address, uint16_t port) {
    struct sockaddr_in saddr_v4 = {};

    saddr_v4.sin_family = AF_INET;
    saddr_v4.sin_port = htons(port);

    auto addr_bytes = address.to_bytes();
    memcpy(&saddr_v4.sin_addr, addr_bytes.data(), sizeof(saddr_v4.sin_addr));

    return saddr_v4;
  }

  struct sockaddr_in6 to_sockaddr(boost::asio::ip::address_v6 address, uint16_t port) {
    struct sockaddr_in6 saddr_v6 = {};

    saddr_v6.sin6_family = AF_INET6;
    saddr_v6.sin6_port = htons(port);
    saddr_v6.sin6_scope_id = address.scope_id();

    auto addr_bytes = address.to_bytes();
    memcpy(&saddr_v6.sin6_addr, addr_bytes.data(), sizeof(saddr_v6.sin6_addr));

    return saddr_v6;
  }

  bool send_batch(batched_send_info_t &send_info) {
    // Fall back to unbatched send calls
    return false;
  }

  bool send(send_info_t &send_info) {
    auto sockfd = (int) send_info.native_socket;
    struct msghdr msg = {};

    // Convert the target address into a sockaddr
    struct sockaddr_in taddr_v4 = {};
    struct sockaddr_in6 taddr_v6 = {};
    if (send_info.target_address.is_v6()) {
      taddr_v6 = to_sockaddr(send_info.target_address.to_v6(), send_info.target_port);

      msg.msg_name = (struct sockaddr *) &taddr_v6;
      msg.msg_namelen = sizeof(taddr_v6);
    } else {
      taddr_v4 = to_sockaddr(send_info.target_address.to_v4(), send_info.target_port);

      msg.msg_name = (struct sockaddr *) &taddr_v4;
      msg.msg_namelen = sizeof(taddr_v4);
    }

    union {
      char buf[std::max(CMSG_SPACE(sizeof(struct in_pktinfo)), CMSG_SPACE(sizeof(struct in6_pktinfo)))];
      struct cmsghdr alignment;
    } cmbuf {};

    socklen_t cmbuflen = 0;

    msg.msg_control = cmbuf.buf;
    msg.msg_controllen = sizeof(cmbuf.buf);

    auto pktinfo_cm = CMSG_FIRSTHDR(&msg);
    if (send_info.source_address.is_v6()) {
      struct in6_pktinfo pktInfo {};

      struct sockaddr_in6 saddr_v6 = to_sockaddr(send_info.source_address.to_v6(), 0);
      pktInfo.ipi6_addr = saddr_v6.sin6_addr;
      pktInfo.ipi6_ifindex = 0;

      cmbuflen += CMSG_SPACE(sizeof(pktInfo));

      pktinfo_cm->cmsg_level = IPPROTO_IPV6;
      pktinfo_cm->cmsg_type = IPV6_PKTINFO;
      pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
      memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
    } else {
      struct in_pktinfo pktInfo {};

      struct sockaddr_in saddr_v4 = to_sockaddr(send_info.source_address.to_v4(), 0);
      pktInfo.ipi_spec_dst = saddr_v4.sin_addr;
      pktInfo.ipi_ifindex = 0;

      cmbuflen += CMSG_SPACE(sizeof(pktInfo));

      pktinfo_cm->cmsg_level = IPPROTO_IP;
      pktinfo_cm->cmsg_type = IP_PKTINFO;
      pktinfo_cm->cmsg_len = CMSG_LEN(sizeof(pktInfo));
      memcpy(CMSG_DATA(pktinfo_cm), &pktInfo, sizeof(pktInfo));
    }

    struct iovec iovs[2] = {};
    int iovlen = 0;
    if (send_info.header) {
      iovs[iovlen].iov_base = (void *) send_info.header;
      iovs[iovlen].iov_len = send_info.header_size;
      iovlen++;
    }
    iovs[iovlen].iov_base = (void *) send_info.payload;
    iovs[iovlen].iov_len = send_info.payload_size;
    iovlen++;

    msg.msg_iov = iovs;
    msg.msg_iovlen = iovlen;

    msg.msg_controllen = cmbuflen;

    auto bytes_sent = sendmsg(sockfd, &msg, 0);

    // If there's no send buffer space, wait for some to be available
    while (bytes_sent < 0 && errno == EAGAIN) {
      struct pollfd pfd;

      pfd.fd = sockfd;
      pfd.events = POLLOUT;

      if (poll(&pfd, 1, -1) != 1) {
        BOOST_LOG(warning) << "poll() failed: "sv << errno;
        break;
      }

      // Try to send again
      bytes_sent = sendmsg(sockfd, &msg, 0);
    }

    if (bytes_sent < 0) {
      BOOST_LOG(warning) << "sendmsg() failed: "sv << errno;
      return false;
    }

    return true;
  }

  // We can't track QoS state separately for each destination on this OS,
  // so we keep a ref count to only disable QoS options when all clients
  // are disconnected.
  static std::atomic<int> qos_ref_count = 0;

  class qos_t: public deinit_t {
  public:
    qos_t(int sockfd, std::vector<std::tuple<int, int, int>> options):
        sockfd(sockfd),
        options(options) {
      qos_ref_count++;
    }

    virtual ~qos_t() {
      if (--qos_ref_count == 0) {
        for (const auto &tuple : options) {
          auto reset_val = std::get<2>(tuple);
          if (setsockopt(sockfd, std::get<0>(tuple), std::get<1>(tuple), &reset_val, sizeof(reset_val)) < 0) {
            BOOST_LOG(warning) << "Failed to reset option: "sv << errno;
          }
        }
      }
    }

  private:
    int sockfd;
    std::vector<std::tuple<int, int, int>> options;
  };

  /**
   * @brief Enables QoS on the given socket for traffic to the specified destination.
   * @param native_socket The native socket handle.
   * @param address The destination address for traffic sent on this socket.
   * @param port The destination port for traffic sent on this socket.
   * @param data_type The type of traffic sent on this socket.
   * @param dscp_tagging Specifies whether to enable DSCP tagging on outgoing traffic.
   */
  std::unique_ptr<deinit_t> enable_socket_qos(uintptr_t native_socket, boost::asio::ip::address &address, uint16_t port, qos_data_type_e data_type, bool dscp_tagging) {
    int sockfd = (int) native_socket;
    std::vector<std::tuple<int, int, int>> reset_options;

    // We can use SO_NET_SERVICE_TYPE to set link-layer prioritization without DSCP tagging
    int service_type = 0;
    switch (data_type) {
      case qos_data_type_e::video:
        service_type = NET_SERVICE_TYPE_VI;
        break;
      case qos_data_type_e::audio:
        service_type = NET_SERVICE_TYPE_VO;
        break;
      default:
        BOOST_LOG(error) << "Unknown traffic type: "sv << (int) data_type;
        break;
    }

    if (service_type) {
      if (setsockopt(sockfd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service_type, sizeof(service_type)) == 0) {
        // Reset SO_NET_SERVICE_TYPE to best-effort when QoS is disabled
        reset_options.emplace_back(std::make_tuple(SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_BE));
      } else {
        BOOST_LOG(error) << "Failed to set SO_NET_SERVICE_TYPE: "sv << errno;
      }
    }

    if (dscp_tagging) {
      int level;
      int option;
      if (address.is_v6()) {
        level = IPPROTO_IPV6;
        option = IPV6_TCLASS;
      } else {
        level = IPPROTO_IP;
        option = IP_TOS;
      }

      // The specific DSCP values here are chosen to be consistent with Windows,
      // except that we use CS6 instead of CS7 for audio traffic.
      int dscp = 0;
      switch (data_type) {
        case qos_data_type_e::video:
          dscp = 40;
          break;
        case qos_data_type_e::audio:
          dscp = 48;
          break;
        default:
          BOOST_LOG(error) << "Unknown traffic type: "sv << (int) data_type;
          break;
      }

      if (dscp) {
        // Shift to put the DSCP value in the correct position in the TOS field
        dscp <<= 2;

        if (setsockopt(sockfd, level, option, &dscp, sizeof(dscp)) == 0) {
          // Reset TOS to -1 when QoS is disabled
          reset_options.emplace_back(std::make_tuple(level, option, -1));
        } else {
          BOOST_LOG(error) << "Failed to set TOS/TCLASS: "sv << errno;
        }
      }
    }

    return std::make_unique<qos_t>(sockfd, reset_options);
  }

  std::string get_host_name() {
    services::function_host_name_provider_t provider {[]() -> std::optional<std::string> {
      try {
        return boost::asio::ip::host_name();
      } catch (boost::system::system_error &err) {
        BOOST_LOG(error) << "Failed to get hostname: "sv << err.what();
        return std::nullopt;
      }
    }};
    return services::host_name_or(provider);
  }

  class macos_high_precision_timer: public high_precision_timer {
  public:
    void sleep_for(const std::chrono::nanoseconds &duration) override {
      std::this_thread::sleep_for(duration);
    }

    operator bool() override {
      return true;
    }
  };

  std::unique_ptr<high_precision_timer> create_high_precision_timer() {
    return std::make_unique<macos_high_precision_timer>();
  }

  std::string
    get_clipboard() {
    // Placeholder
    return "";
  }

  bool
    set_clipboard(const std::string &content) {
    // Placeholder
    return false;
  }

  std::string resolve_render_device() {
    return {};
  }
}  // namespace platf

namespace dyn {
  void *handle(const std::vector<const char *> &libs) {
    void *handle;

    for (auto lib : libs) {
      handle = dlopen(lib, RTLD_LAZY | RTLD_LOCAL);
      if (handle) {
        return handle;
      }
    }

    std::stringstream ss;
    ss << "Couldn't find any of the following libraries: ["sv << libs.front();
    std::for_each(std::begin(libs) + 1, std::end(libs), [&](auto lib) {
      ss << ", "sv << lib;
    });

    ss << ']';

    BOOST_LOG(error) << ss.str();

    return nullptr;
  }

  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict) {
    int err = 0;
    for (auto &func : funcs) {
      TUPLE_2D_REF(fn, name, func);

      *fn = (void (*)()) dlsym(handle, name);

      if (!*fn && strict) {
        BOOST_LOG(error) << "Couldn't find function: "sv << name;

        err = -1;
      }
    }

    return err;
  }
}  // namespace dyn

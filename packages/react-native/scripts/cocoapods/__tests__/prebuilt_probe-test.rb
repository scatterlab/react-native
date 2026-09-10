# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

require "test/unit"
require "socket"
require_relative "../utils.rb"
require_relative "../rndependencies.rb"
require_relative "../rncore.rb"

# The suite shares one process, so another test file may have loaded PodMock and
# made Pod::UI resolvable. The logs then run through CocoaPods' colorize helpers,
# which only exist inside the real pod binary.
unless String.method_defined?(:green)
    class String
        def green; self; end
        def red; self; end
        def yellow; self; end
    end
end

class PrebuiltProbeTests < Test::Unit::TestCase

    ENV_KEYS = %w[RCT_USE_RN_DEP RCT_USE_PREBUILT_RNCORE RCT_USE_LOCAL_RN_DEP ENTERPRISE_REPOSITORY CURL_HOME]

    def setup
        @saved_env = ENV_KEYS.to_h { |key| [key, ENV[key]] }
        @servers = []
    end

    def teardown
        @saved_env.each { |key, value| ENV[key] = value }
        @servers.each { |server| stop_server(server) }
        ReactNativeDependenciesUtils.class_variable_set(:@@react_native_version, "")
        ReactNativeDependenciesUtils.class_variable_set(:@@build_from_source, true)
        ReactNativeCoreUtils.class_variable_set(:@@fork_prebuilt_published, nil)
        if @original_fork_url
            ReactNativeCoreUtils.singleton_class.send(:define_method, :fork_stable_tarball_url, @original_fork_url)
            @original_fork_url = nil
        end
    end

    # A real HTTP server, so the assertions cover what curl actually does with
    # our flags (redirects, retries, --write-out) rather than a stubbed exit code.
    # `responses` is called with the 1-based request number and returns
    # [status line, extra headers].
    def start_server(&responses)
        socket = TCPServer.new("127.0.0.1", 0)
        state = { :socket => socket, :requests => [], :port => socket.addr[1] }
        state[:thread] = Thread.new do
            loop do
                client = socket.accept
                request_line = client.gets
                while (line = client.gets) && line != "\r\n"; end
                state[:requests] << request_line
                status, headers = responses.call(state[:requests].length)
                client.write("HTTP/1.1 #{status}\r\nContent-Length: 0\r\nConnection: close\r\n#{headers}\r\n")
                client.close
            end
        end
        @servers << state
        state
    end

    def stop_server(state)
        state[:thread]&.kill
        state[:thread]&.join
        state[:socket]&.close
    end

    def url_for(state, path = "/artifact.tar.gz")
        "http://127.0.0.1:#{state[:port]}#{path}"
    end

    # An address nothing listens on: curl fails at the transport layer, so there
    # is no HTTP status to read.
    UNREACHABLE_URL = "http://127.0.0.1:1/artifact.tar.gz"

    # ================================== #
    # TEST - probe_artifact              #
    # ================================== #

    def test_probeArtifact_when200_reportsOk
        server = start_server { ["200 OK", ""] }

        result = ReactNativePodsUtils.probe_artifact(url_for(server))

        assert_true(result[:ok])
        assert_equal("200", result[:http_code])
        assert_equal(0, result[:curl_exit])
        assert_equal(1, server[:requests].length)
        assert_true(server[:requests].first.start_with?("HEAD "))
    end

    def test_probeArtifact_whenRedirected_followsToTheFinalStatus
        server = start_server { |n| n == 1 ? ["302 Found", "Location: /moved\r\n"] : ["200 OK", ""] }

        result = ReactNativePodsUtils.probe_artifact(url_for(server))

        assert_true(result[:ok])
        assert_equal(2, server[:requests].length)
    end

    def test_probeArtifact_whenTheHostBlipsOnce_retriesAndSucceeds
        server = start_server { |n| n == 1 ? ["503 Service Unavailable", ""] : ["200 OK", ""] }

        result = ReactNativePodsUtils.probe_artifact(url_for(server))

        assert_true(result[:ok])
        assert_equal("200", result[:http_code])
        assert_equal(2, server[:requests].length)
    end

    def test_probeArtifact_when404_reportsTheStatusAfterBoundedRetries
        server = start_server { ["404 Not Found", ""] }

        result = ReactNativePodsUtils.probe_artifact(url_for(server))

        assert_false(result[:ok])
        assert_equal("404", result[:http_code])
        assert_equal(3, server[:requests].length)
    end

    def test_probeArtifact_whenTheHostIsUnreachable_reportsTheCurlExitCode
        result = ReactNativePodsUtils.probe_artifact(UNREACHABLE_URL)

        assert_false(result[:ok])
        assert_not_equal(0, result[:curl_exit])
        assert_true(result[:summary].include?("curl exit #{result[:curl_exit]}"))
    end

    # Built by hand rather than with tmpdir: that library pulls in the real
    # FileUtils, which would replace the suite's FileUtils mock for every test
    # loaded after this file.
    def test_probeArtifact_whenTheRunnerCustomisesCurlOutput_ignoresIt
        dir = File.join(ENV["TMPDIR"] || "/tmp", "rn-prebuilt-probe-#{Process.pid}")
        curlrc = File.join(dir, ".curlrc")
        Dir.mkdir(dir) unless Dir.exist?(dir)
        File.write(curlrc, "write-out = \"polluted\"\n")
        ENV["CURL_HOME"] = dir
        server = start_server { ["200 OK", ""] }

        result = ReactNativePodsUtils.probe_artifact(url_for(server))

        assert_true(result[:ok])
        assert_equal("200", result[:http_code])
    ensure
        File.unlink(curlrc) if File.exist?(curlrc)
        Dir.rmdir(dir) if Dir.exist?(dir)
    end

    # Proxies and enterprise mirrors carry credentials in the URL, and curl's
    # stderr echoes them back.
    def test_probeArtifact_summaryCarriesTheHostButNotThePathOrQuery
        server = start_server { ["200 OK", ""] }

        result = ReactNativePodsUtils.probe_artifact(url_for(server, "/private/artifact.tar.gz?token=s3cr3t"))

        assert_true(result[:summary].include?("127.0.0.1"))
        assert_false(result[:summary].include?("s3cr3t"))
        assert_false(result[:summary].include?("private"))
    end

    # ============================================= #
    # TEST - setup_react_native_dependencies        #
    # ============================================= #

    def setup_deps_against(server)
        ENV["ENTERPRISE_REPOSITORY"] = "http://127.0.0.1:#{server[:port]}"
        ReactNativeDependenciesUtils.setup_react_native_dependencies("/rn", "0.87.1-scatterlab.2")
    end

    def test_setupDeps_whenCoreIsPrebuiltAndTheArtifactIsUnavailable_abortsBeforePodResolution
        ENV["RCT_USE_RN_DEP"] = "1"
        ENV["RCT_USE_PREBUILT_RNCORE"] = "1"
        server = start_server { ["404 Not Found", ""] }

        error = assert_raise(SystemExit) { setup_deps_against(server) }

        assert_true(error.message.include?("404"))
    end

    def test_setupDeps_whenCoreIsPrebuiltAndDepsAreOptedOut_aborts
        ENV["RCT_USE_RN_DEP"] = "0"
        ENV["RCT_USE_PREBUILT_RNCORE"] = "1"

        assert_raise(SystemExit) do
            ReactNativeDependenciesUtils.setup_react_native_dependencies("/rn", "0.87.1-scatterlab.2")
        end
    end

    # Source core + source deps is a consistent pair, so upstream's fallback stays.
    def test_setupDeps_whenCoreIsBuiltFromSource_fallsBackToSourceWithoutAborting
        ENV["RCT_USE_RN_DEP"] = "1"
        ENV["RCT_USE_PREBUILT_RNCORE"] = "0"
        server = start_server { ["404 Not Found", ""] }

        setup_deps_against(server)

        assert_true(ReactNativeDependenciesUtils.build_react_native_deps_from_source())
    end

    # ============================================= #
    # TEST - fork prebuilt core probe               #
    # ============================================= #

    # The release URL comes from a constant pointing at github.com; redirect it so
    # the probe still runs end to end against a host we control.
    def stub_fork_release_url(url)
        @original_fork_url = ReactNativeCoreUtils.method(:fork_stable_tarball_url).unbind
        ReactNativeCoreUtils.singleton_class.send(:define_method, :fork_stable_tarball_url) { |*| url }
    end

    def test_coreArtifactExists_whenTheHostBlipsOnce_retriesAndReportsPublished
        server = start_server { |n| n == 1 ? ["503 Service Unavailable", ""] : ["200 OK", ""] }

        assert_true(ReactNativeCoreUtils.artifact_exists(url_for(server)))
        assert_equal(2, server[:requests].length)
    end

    # "Run the build workflow" is the wrong instruction when the release is there
    # and the network is not.
    def test_forkPrebuiltPublished_whenTheHostIsUnreachable_abortsWithTheTransportReason
        stub_fork_release_url(UNREACHABLE_URL)

        error = assert_raise(SystemExit) { ReactNativeCoreUtils.fork_prebuilt_published?("0.87.1-scatterlab.2") }

        assert_true(error.message.include?("curl exit"))
        assert_false(error.message.include?("no prebuilt release was found"))
    end
end

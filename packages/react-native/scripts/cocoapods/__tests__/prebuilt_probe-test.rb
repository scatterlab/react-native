# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

require "test/unit"
require "socket"
require_relative "../utils.rb"
require_relative "../rndependencies.rb"
require_relative "../rncore.rb"

class PrebuiltProbeTests < Test::Unit::TestCase

    ENV_KEYS = %w[PATH RCT_USE_RN_DEP RCT_USE_PREBUILT_RNCORE RCT_USE_LOCAL_RN_DEP RCT_TESTONLY_RNCORE_TARBALL_PATH ENTERPRISE_REPOSITORY CURL_HOME]

    def setup
        @saved_env = ENV_KEYS.to_h { |key| [key, ENV[key]] }
        @servers = []
        install_color_shim
    end

    # Another test file may have loaded PodMock, which makes Pod::UI resolvable,
    # and the logs then run through CocoaPods' colorize helpers - they only exist
    # inside the real pod binary. Defining them for the whole process changes how
    # later test files behave (utils-test.rb reports different errors with them
    # present), so they live only for the duration of one test.
    COLORS = [:green, :red, :yellow]

    def install_color_shim
        @color_shim = COLORS.reject { |name| String.method_defined?(name) }
        @color_shim.each { |name| String.send(:define_method, name) { self } }
    end

    def remove_color_shim
        @color_shim.to_a.each { |name| String.send(:remove_method, name) }
    end

    def teardown
        @saved_env.each { |key, value| ENV[key] = value }
        @servers.each { |server| stop_server(server) }
        ReactNativeDependenciesUtils.class_variable_set(:@@react_native_version, "")
        ReactNativeDependenciesUtils.class_variable_set(:@@build_from_source, true)
        ReactNativeCoreUtils.class_variable_set(:@@fork_prebuilt_published, nil)
        ReactNativeCoreUtils.class_variable_set(:@@react_native_version, "")
        ReactNativeCoreUtils.class_variable_set(:@@build_from_source, true)
        remove_color_shim
        if @original_fork_url
            ReactNativeCoreUtils.singleton_class.send(:define_method, :fork_stable_tarball_url, @original_fork_url)
            @original_fork_url = nil
        end
    end

    # A real HTTP server, so the assertions cover what curl actually does with
    # our flags (redirects, retries, --write-out) rather than a stubbed exit code.
    # `responses` is called with the 1-based request number and the request line
    # (so a test can answer the core and deps artifacts differently) and returns
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
                status, headers = responses.call(state[:requests].length, request_line)
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

    # `proxy` and not `write-out`: curl reads the config first and the command
    # line second, so a curlrc cannot override a flag we pass. What it CAN do is
    # add settings we pass none of - a proxy, a resolve override, insecure - and
    # those decide whether the probe reaches the host at all.
    #
    # Built by hand rather than with tmpdir: that library pulls in the real
    # FileUtils, which would replace the suite's FileUtils mock for every test
    # loaded after this file.
    def test_probeArtifact_whenTheRunnerConfiguresAProxy_ignoresIt
        dir = File.join(ENV["TMPDIR"] || "/tmp", "rn-prebuilt-probe-#{Process.pid}")
        curlrc = File.join(dir, ".curlrc")
        Dir.mkdir(dir) unless Dir.exist?(dir)
        File.write(curlrc, "proxy = \"http://127.0.0.1:1\"\n")
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

    # ENTERPRISE_REPOSITORY is a documented user-supplied base URL, so the value
    # reaching the probe is not always parseable. URI::InvalidURIError quotes the
    # whole URL in its message, which is exactly what must never be logged.
    def test_probeArtifact_whenTheUrlIsUnparseable_reportsItWithoutRaisingOrEchoingTheUrl
        result = ReactNativePodsUtils.probe_artifact("https://user:s3cr3t@ho|st/artifact.tar.gz")

        assert_false(result[:ok])
        assert_false(result[:summary].include?("s3cr3t"))
        assert_false(result[:summary].include?("artifact.tar.gz"))
    end

    def test_probeArtifact_whenTheUrlIsBlank_reportsItWithoutRaising
        result = ReactNativePodsUtils.probe_artifact("")

        assert_false(result[:ok])
        assert_true(result[:summary].include?("unknown host"))
    end

    # ============================================= #
    # TEST - setup_react_native_dependencies        #
    # ============================================= #

    VERSION = "0.87.1-scatterlab.2"

    def setup_deps_against(server)
        ENV["ENTERPRISE_REPOSITORY"] = "http://127.0.0.1:#{server[:port]}"
        ReactNativeDependenciesUtils.setup_react_native_dependencies("/rn", VERSION)
    end

    # use_react_native! runs deps first and core second (react_native_pods.rb:145,
    # :148), and the pair is only decidable once both have run.
    def setup_pair_against(server)
        setup_deps_against(server)
        ReactNativeCoreUtils.setup_rncore("/rn", VERSION)
    end

    # Answer the deps artifact and the core artifact differently.
    def server_answering(deps:, core:)
        start_server do |_n, request|
            [request.include?("-dependencies-") ? deps : core, ""]
        end
    end

    def test_setupPair_whenCoreIsPrebuiltAndTheDepsArtifactIsUnavailable_abortsBeforePodResolution
        ENV["RCT_USE_RN_DEP"] = "1"
        ENV["RCT_USE_PREBUILT_RNCORE"] = "1"
        server = server_answering(:deps => "404 Not Found", :core => "200 OK")
        stub_fork_release_url(url_for(server, "/react-native-artifacts-core-debug.tar.gz"))

        error = assert_raise(SystemExit) { setup_pair_against(server) }

        assert_true(error.message.include?("404"))
    end

    def test_setupPair_whenCoreIsPrebuiltAndDepsAreOptedOut_aborts
        ENV["RCT_USE_RN_DEP"] = "0"
        ENV["RCT_USE_PREBUILT_RNCORE"] = "1"
        server = server_answering(:deps => "404 Not Found", :core => "200 OK")
        stub_fork_release_url(url_for(server, "/react-native-artifacts-core-debug.tar.gz"))

        assert_raise(SystemExit) { setup_pair_against(server) }
    end

    # A local core tarball makes the core prebuilt even with
    # RCT_USE_PREBUILT_RNCORE=0 (rncore.rb:76-78), so the env var alone cannot
    # decide the pair.
    def test_setupPair_whenCoreIsPrebuiltFromALocalTarball_aborts
        tarball = File.join(ENV["TMPDIR"] || "/tmp", "rn-local-core-#{Process.pid}.tar.gz")
        File.write(tarball, "")
        ENV["RCT_TESTONLY_RNCORE_TARBALL_PATH"] = tarball
        ENV["RCT_USE_RN_DEP"] = "0"
        ENV["RCT_USE_PREBUILT_RNCORE"] = "0"

        assert_raise(SystemExit) do
            ReactNativeDependenciesUtils.setup_react_native_dependencies("/rn", VERSION)
            ReactNativeCoreUtils.setup_rncore("/rn", VERSION)
        end
    ensure
        File.unlink(tarball) if File.exist?(tarball)
    end

    # With FORK_REQUIRES_OWN_PREBUILT off, an unreachable artifact host drops the
    # core to source too. That pair is consistent and used to build fine, so the
    # invariant must read the core's actual result and not the env var.
    def test_setupPair_whenBothFallBackToSource_doesNotAbort
        ENV["RCT_USE_RN_DEP"] = "1"
        ENV["RCT_USE_PREBUILT_RNCORE"] = "1"
        without_fork_prebuilt_requirement do
            server = server_answering(:deps => "404 Not Found", :core => "404 Not Found")
            stub_fork_release_url(url_for(server, "/react-native-artifacts-core-debug.tar.gz"))

            begin
                setup_pair_against(server)
            rescue SystemExit => error
                flunk("aborted on a consistent source/source pair: #{error.message}")
            end

            assert_true(ReactNativeDependenciesUtils.build_react_native_deps_from_source())
            assert_true(ReactNativeCoreUtils.build_rncore_from_source())
        end
    end

    def without_fork_prebuilt_requirement
        previous = ReactNativeCoreUtils.const_get(:FORK_REQUIRES_OWN_PREBUILT)
        silence_warnings { ReactNativeCoreUtils.const_set(:FORK_REQUIRES_OWN_PREBUILT, false) }
        yield
    ensure
        silence_warnings { ReactNativeCoreUtils.const_set(:FORK_REQUIRES_OWN_PREBUILT, previous) }
    end

    def silence_warnings
        previous = $VERBOSE
        $VERBOSE = nil
        yield
    ensure
        $VERBOSE = previous
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
        assert_true(error.message.include?("did not answer"))
    end

    # The other half of the same message: a 404 means the release was never cut,
    # and that is the case CLAUDE.md calls out as the dangerous partial release.
    def test_forkPrebuiltPublished_whenTheReleaseIsMissing_abortsSayingSo
        server = start_server { ["404 Not Found", ""] }
        stub_fork_release_url(url_for(server))

        error = assert_raise(SystemExit) { ReactNativeCoreUtils.fork_prebuilt_published?(VERSION) }

        assert_true(error.message.include?("no prebuilt release exists"))
    end

    # curl absent from PATH used to fall back silently (exit 127); it must not
    # raise out of a Podfile now that the probe decides whether to abort.
    def test_probeArtifact_whenCurlIsNotInstalled_reportsItInsteadOfRaising
        ENV["PATH"] = ""

        result = ReactNativePodsUtils.probe_artifact("https://example.com/artifact.tar.gz")

        assert_false(result[:ok])
        assert_true(result[:summary].include?("curl exit not found"))
    end
end

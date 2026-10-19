# frozen_string_literal: true

require "spec_helper"

$LOAD_PATH.unshift(File.expand_path("../tools/lib", __dir__))
require "feedstock"

# The node release monitor's pure core (the propose-bump shape): the
# url-derived version anchor, the SHASUMS256.txt parse, and the
# line-level Tebakofile rewrite. The network edge (index.json, the two
# SHASUMS fetches) stays outside the suite — the risky logic is the
# edit, and the edit is fully deterministic here.
#
# The rewrite's invariants, locked:
#   * every nodejs.org url moves (both dist roots — official and
#     unofficial-builds carry the version twice: path + asset name);
#   * each url's following sha256: line receives that url's asset
#     digest from the new SHASUMS — paired, never positional beyond the
#     one-line adjacency the file itself guarantees;
#   * the standalone version: "<full semver>" line moves with them and
#     NO other version: key does (the tools pins carry their own
#     version: keys — tebako line pins — and must never be caught);
#   * a digest miss is a named error raised BEFORE the caller writes.
RSpec.describe "Feedstock::ReleaseMonitor" do
  let(:tebakofile_snippet) do
    <<~YAML
      tools:
        tebako:
          version: "2.8.22"
      flavors:
        official:
          version: "24.21.0"
          sources:
            - platform: "aarch64-macos"
              url: "https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz"
              sha256: "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057"
              strip_components: 1
            - platform: "x86_64-linux-musl"
              url: "https://unofficial-builds.nodejs.org/download/release/v24.21.0/node-v24.21.0-linux-x64-musl.tar.gz"
              sha256: "01a713e34da98e7b4d2a3191ee7ca3f93dd0384d1a2ef23c379b2161ee6e133a"
              strip_components: 1
    YAML
  end

  let(:shasums) do
    Feedstock::ReleaseMonitor.parse_shasums(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  node-v24.22.0-darwin-arm64.tar.gz\n" \
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  node-v24.22.0-linux-x64-musl.tar.gz\n" \
      "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  node-v24.22.0-darwin-x64.tar.gz\n"
    )
  end

  it "anchors the current version on the source urls, never a version: key" do
    expect(Feedstock::ReleaseMonitor.current_version(tebakofile_snippet)).to eq("24.21.0")
  end

  it "raises by name when the url anchor is gone" do
    expect { Feedstock::ReleaseMonitor.current_version("version: \"24.21.0\"\n") }
      .to raise_error(Feedstock::FeedstockError, /no node-v<version>- source url/)
  end

  it "parses SHASUMS256.txt lines into a basename → digest map" do
    expect(shasums["node-v24.22.0-linux-x64-musl.tar.gz"]).to eq("b" * 64)
    expect(shasums.keys.length).to eq(3)
  end

  it "rewrites both dist urls, their paired digests, and the flavor's version line" do
    updated, touched = Feedstock::ReleaseMonitor.rewrite(tebakofile_snippet, "24.21.0", "24.22.0", shasums)
    expect(touched).to eq(2)
    expect(updated).to include("dist/v24.22.0/node-v24.22.0-darwin-arm64.tar.gz")
    expect(updated).to include("release/v24.22.0/node-v24.22.0-linux-x64-musl.tar.gz")
    expect(updated).to include("sha256: \"#{'a' * 64}\"")
    expect(updated).to include("sha256: \"#{'b' * 64}\"")
    expect(updated).not_to include("24.21.0")
  end

  it "never touches the tools pin's version: key" do
    updated, = Feedstock::ReleaseMonitor.rewrite(tebakofile_snippet, "24.21.0", "24.22.0", shasums)
    expect(updated).to include('version: "2.8.22"')
  end

  it "raises by name on a digest miss before anything can be written" do
    expect { Feedstock::ReleaseMonitor.rewrite(tebakofile_snippet, "24.21.0", "24.22.0", {}) }
      .to raise_error(Feedstock::FeedstockError, /no SHASUMS256.txt entry for node-v24\.22\.0-darwin-arm64\.tar\.gz/)
  end
end

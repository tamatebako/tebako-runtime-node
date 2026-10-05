# frozen_string_literal: true

require "spec_helper"
require "base64"
require "digest"
require "json"
require "tmpdir"
require "yaml"

# The tool under test rides the load path (the repo's no-require_relative
# rule; the sibling factories' $LOAD_PATH idiom). tools/lib joins through
# registry_update.rb's own unshift.
$LOAD_PATH.unshift(File.expand_path("../tools", __dir__))
require "registry_update"

# Recording stand-ins in the release-spec idiom: the renderer accepts
# any client object, and every interaction is observable through the fake.
RegistrySpecRelease = Struct.new(:url, :tag_name)
RegistrySpecAsset = Struct.new(:name, :browser_download_url)
RegistrySpecContents = Struct.new(:content)

# The Octokit stand-in: one release carrying shard assets whose bodies are
# canned JSON, and a contents-API registry source that is a static
# document, a proc (so a spec can read back what the last run wrote), or
# Octokit::NotFound (no registry on main yet).
class FakeRegistryClient
  def initialize(release:, shards:, registry: nil)
    @release = release
    @shards = shards
    @registry = registry
  end

  def release_for_tag(_repo, _tag)
    @release
  end

  def release_assets(url)
    url == @release.url ? @shards.map(&:first) : []
  end

  def get(url)
    @shards.to_h { |asset, body| [asset.browser_download_url, body] }.fetch(url)
  end

  def contents(_repo, **)
    source = @registry.respond_to?(:call) ? @registry.call : @registry
    raise Octokit::NotFound if source.nil?

    RegistrySpecContents.new(Base64.strict_encode64(source))
  end
end

RSpec.describe RegistryUpdate do
  let(:version) { "9.9.9" }

  # The build-workflow fixture: the matrix block the asset-platform →
  # triplet mapping flows from (mirrors the real workflow's shape).
  MATRIX_FIXTURE = <<~YAML
    name: build-payload
    jobs:
      build:
        strategy:
          matrix:
            flavor: [official]
            platform:
              - {triplet: aarch64-macos, asset_platform: macos-arm64, exe_suffix: ""}
              - {triplet: x86_64-macos, asset_platform: macos-x86_64, exe_suffix: ""}
              - {triplet: x86_64-linux-gnu, asset_platform: linux-gnu-x86_64, exe_suffix: ""}
              - {triplet: aarch64-linux-gnu, asset_platform: linux-gnu-arm64, exe_suffix: ""}
              - {triplet: x86_64-linux-musl, asset_platform: linux-musl-x86_64, exe_suffix: ""}
              - {triplet: aarch64-linux-musl, asset_platform: linux-musl-arm64, exe_suffix: ""}
              - {triplet: x86_64-windows-ucrt, asset_platform: windows-ucrt64, exe_suffix: .exe}
  YAML

  # A release shard as tools/build writes it (the release's
  # machine-readable unit, spec 13 §2a): the exe pair's own fields plus
  # the `image` block the registry mirrors. `name_suffix` mints a second
  # asset claiming the same platform (the duplicate-triplet case).
  # `new_era` mints the post-tebako#716 spelling (the implementation
  # segment in the stem — what tools/build writes from this branch on).
  def shard(implementation:, node:, platform:, tebako_version: version, image: :default, name_suffix: "", new_era: false)
    exe_suffix = platform.start_with?("windows") ? ".exe" : ""
    stem = if new_era
             "tebako-runtime-#{tebako_version}-#{implementation}-#{node}-#{platform}#{name_suffix}"
           else
             "tebako-runtime-#{tebako_version}-#{node}-#{platform}#{name_suffix}"
           end
    body = { "tebako_version" => tebako_version, "node_version" => node,
             "implementation" => implementation, "platform" => platform,
             "filename" => "#{stem}#{exe_suffix}",
             "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}#{exe_suffix}") }
    case image
    when :default
      body["image"] = { "filename" => "#{stem}.tfs",
                        "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs") }
    when :absent
      # no image key at all — the missing-keys refusal
    else
      body["image"] = image
    end
    asset = RegistrySpecAsset.new("#{stem}.manifest.json", "https://download.test/#{stem}.manifest.json")
    [asset, JSON.generate(body)]
  end

  def shards_of(*list)
    list.map { |args| shard(**args) }
  end

  def render(shards, registry: nil, version_override: nil)
    ver = version_override || version
    Dir.mktmpdir do |dir|
      matrix_path = File.join(dir, "build-payload.yml")
      File.write(matrix_path, MATRIX_FIXTURE)
      path = File.join(dir, "tpkg-registry.yaml")
      release = RegistrySpecRelease.new("https://api.test/releases/1", "v#{ver}")
      client = FakeRegistryClient.new(release: release, shards: shards, registry: registry)
      described_class.new(client: client,
                          env: { "TEBAKO_VERSION" => ver, "REGISTRY_PATH" => path,
                                 "MATRIX_PATH" => matrix_path }).run
      yield path if block_given?
      return File.read(path)
    end
  end

  def payload_named(doc, name)
    doc["payloads"].find { |p| p["name"] == name }
  end

  it "derives the registry from the shards: composite <node>-<tebako> versions, image-mirroring triplet rows" do
    shards = shards_of({ implementation: "node", node: "24.20.0", platform: "macos-arm64" },
                       { implementation: "node", node: "24.21.0", platform: "macos-arm64" },
                       { implementation: "node", node: "24.21.0", platform: "windows-ucrt64" },
                       { implementation: "node", node: "24.21.0", platform: "linux-musl-x86_64" })
    doc = YAML.safe_load(render(shards))

    expect(doc["schema_version"]).to eq(1)
    expect(doc["payloads"].map { |p| p["name"] }).to contain_exactly("node")

    payload = payload_named(doc, "node")
    expect(payload["kind"]).to eq("runtime")
    # The MINOR-1 edge-discovery key — an engine-less runtime entry is
    # invisible to `kind: runtime` edges.
    expect(payload["engine"]).to eq("node")
    # Numeric sort, never lexical: 24.20.0-… < 24.21.0-….
    expect(payload["versions"].map { |v| v["version"] }).to eq(["24.20.0-9.9.9", "24.21.0-9.9.9"])
    v = payload["versions"].find { |x| x["version"] == "24.21.0-9.9.9" }
    expect(v["implementation"]).to eq("node")
    expect(v["platforms"].keys).to eq(%w[aarch64-macos x86_64-linux-musl x86_64-windows-ucrt])
    stem = "tebako-runtime-9.9.9-24.21.0-macos-arm64"
    # The row mirrors the ENV IMAGE (never the exe — that is this
    # registry's shipped grammar).
    expect(v["platforms"]["aarch64-macos"])
      .to eq("artifact" => "#{stem}.tfs", "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs"))
    expect(v["release"]).to eq("ref" => "tfs:github:tamatebako/tebako-runtime-node:v9.9.9")
    expect(payload["default"]).to eq("24.21.0-9.9.9")
  end

  it "names a non-default implementation's payload with its suffix (the spec 28 §8 flavor axis)" do
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64" },
                       { implementation: "forkline", node: "24.21.0", platform: "linux-gnu-x86_64" })
    doc = YAML.safe_load(render(shards))

    expect(doc["payloads"].map { |p| p["name"] }).to contain_exactly("node", "node-forkline")
    forked = payload_named(doc, "node-forkline")
    expect(forked["engine"]).to eq("node")
    expect(forked["versions"].first["implementation"]).to eq("forkline")
    expect(forked["versions"].first["version"]).to eq("24.21.0-9.9.9")
  end

  # tebako#716: a post-flip shard's filenames carry the implementation
  # segment — the renderer mirrors the shard's own strings verbatim,
  # never recomposes a name, so the new spelling flows through untouched
  # (and the segment-less spellings above keep flowing as published).
  it "mirrors a post-tebako#716 (implementation-segment) artifact name verbatim" do
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64", new_era: true },
                       { implementation: "node", node: "24.21.0", platform: "windows-ucrt64", new_era: true })
    doc = YAML.safe_load(render(shards))

    payload = payload_named(doc, "node")
    v = payload["versions"].find { |x| x["version"] == "24.21.0-9.9.9" }
    stem = "tebako-runtime-9.9.9-node-24.21.0-macos-arm64"
    expect(v["platforms"]["aarch64-macos"])
      .to eq("artifact" => "#{stem}.tfs", "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs"))
    expect(v["platforms"]["x86_64-windows-ucrt"]["artifact"])
      .to eq("tebako-runtime-9.9.9-node-24.21.0-windows-ucrt64.tfs")
  end

  it "upserts into an existing registry, preserving other payloads and withdrawn marks" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: metanorma
          kind: app
          versions:
            - version: '1.2.3'
              platforms: universal
              release: {ref: tfs:github:tebako-packages/metanorma:1.2.3}
        - name: node
          kind: runtime
          versions:
            - version: '24.20.0-9.9.8'
              implementation: node
              status: withdrawn
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-9.9.8-24.20.0-macos-arm64.tfs
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-node:v9.9.8}
          default: '24.20.0-9.9.8'
    YAML
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "linux-gnu-x86_64" })
    doc = YAML.safe_load(render(shards, registry: existing))

    expect(doc["payloads"].map { |p| p["name"] }).to contain_exactly("metanorma", "node")
    payload = payload_named(doc, "node")
    old = payload["versions"].find { |v| v["version"] == "24.20.0-9.9.8" }
    expect(old["status"]).to eq("withdrawn")
    expect(old["platforms"]).to have_key("aarch64-macos")
    new = payload["versions"].find { |v| v["version"] == "24.21.0-9.9.9" }
    stem = "tebako-runtime-9.9.9-24.21.0-linux-gnu-x86_64"
    expect(new["platforms"]).to eq("x86_64-linux-gnu" => {
                                     "artifact" => "#{stem}.tfs",
                                     "sha256" => Digest::SHA256.hexdigest("BYTES-#{stem}.tfs")
                                   })
    # The default moves off the withdrawn line onto the live one.
    expect(payload["default"]).to eq("24.21.0-9.9.9")
  end

  it "keeps every tebako line addressable: a reline is a NEW composite version, never a row rewrite" do
    first = render(shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64" }))
    reline = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64",
                         tebako_version: "9.9.10" },
                       { implementation: "node", node: "24.21.0", platform: "linux-gnu-x86_64",
                         tebako_version: "9.9.10" })
    doc = YAML.safe_load(render(reline, registry: first, version_override: "9.9.10"))

    payload = payload_named(doc, "node")
    expect(payload["versions"].map { |v| v["version"] }).to eq(["24.21.0-9.9.9", "24.21.0-9.9.10"])
    row = payload["versions"].find { |v| v["version"] == "24.21.0-9.9.10" }
    expect(row["platforms"].keys).to eq(%w[aarch64-macos x86_64-linux-gnu])
    expect(row["release"]).to eq("ref" => "tfs:github:tamatebako/tebako-runtime-node:v9.9.10")
    expect(payload["default"]).to eq("24.21.0-9.9.10")
  end

  it "unions platform rows when one composite version gains legs (new rows win per triplet)" do
    first = render(shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64" }))
    more = shards_of({ implementation: "node", node: "24.21.0", platform: "linux-musl-arm64" })
    doc = YAML.safe_load(render(more, registry: first))

    payload = payload_named(doc, "node")
    row = payload["versions"].find { |v| v["version"] == "24.21.0-9.9.9" }
    expect(row["platforms"].keys).to eq(%w[aarch64-linux-musl aarch64-macos])
  end

  it "is byte-idempotent: rendering over its own output changes nothing" do
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64" },
                       { implementation: "node", node: "24.21.0", platform: "windows-ucrt64" })
    first = render(shards)
    second = render(shards, registry: -> { first })
    expect(second).to eq(first)
  end

  it "carries the ownership header (never hand-edit except status: withdrawn)" do
    output = render(shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64" }))
    expect(output).to include("OWNED BY tools/registry_update.rb")
    expect(output).to include("status: withdrawn")
  end

  it "seeds the document when main carries no registry yet" do
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64" })
    doc = YAML.safe_load(render(shards, registry: nil))
    expect(doc["schema_version"]).to eq(1)
    expect(doc["payloads"].map { |p| p["name"] }).to eq(["node"])
  end

  it "drops the default loudly when every version is withdrawn" do
    # The withdrawn entry's own release re-renders (the version key is
    # unchanged), the merge preserves the mark, and no live line remains
    # for `default:` to name.
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: node
          kind: runtime
          versions:
            - version: '24.21.0-9.9.9'
              implementation: node
              status: withdrawn
              platforms:
                aarch64-macos:
                  artifact: tebako-runtime-9.9.9-24.21.0-macos-arm64.tfs
                  sha256: 'aaaa'
              release: {ref: tfs:github:tamatebako/tebako-runtime-node:v9.9.9}
          default: '24.21.0-9.9.9'
    YAML
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64" })
    output = nil
    expect do
      output = render(shards, registry: existing)
    end.to output(/no default/).to_stderr
    payload = payload_named(YAML.safe_load(output), "node")
    expect(payload).not_to have_key("default")
    expect(payload["versions"].first["status"]).to eq("withdrawn")
  end

  it "fails named when an existing version carries `platforms: universal` (never both shapes)" do
    existing = <<~YAML
      schema_version: 1
      payloads:
        - name: node
          kind: runtime
          versions:
            - version: '24.21.0-9.9.9'
              implementation: node
              platforms: universal
              release: {ref: tfs:github:tamatebako/tebako-runtime-node:v9.9.9}
    YAML
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64" })
    expect { render(shards, registry: existing) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /never both/)
  end

  it "fails named when a shard declares another tebako version" do
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64",
                         tebako_version: "0.0.1" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /declares tebako_version "0\.0\.1"/)
  end

  it "fails named when a shard names an unknown platform" do
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "plan9-arm64" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /unknown platform "plan9-arm64"/)
  end

  it "fails named when two shards claim the same triplet for one flavor" do
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64",
                         name_suffix: "-a" },
                       { implementation: "node", node: "24.21.0", platform: "macos-arm64",
                         name_suffix: "-b" })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /two shards claim aarch64-macos/)
  end

  it "fails named when a shard's image block is malformed (the registry mirrors the env image)" do
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64",
                         image: {} })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /carries no image \{filename, sha256\} block/)
  end

  it "fails named when a shard omits the image key entirely" do
    shards = shards_of({ implementation: "node", node: "24.21.0", platform: "macos-arm64",
                         image: :absent })
    expect { render(shards) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /is missing image/)
  end

  it "fails named when a shard is missing a required key" do
    asset, body = shard(implementation: "node", node: "24.21.0", platform: "macos-arm64")
    broken = JSON.generate(JSON.parse(body).reject { |key, _| key == "implementation" })
    expect { render([[asset, broken]]) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /is missing implementation/)
  end

  it "fails named when the tag has no release" do
    Dir.mktmpdir do |dir|
      matrix_path = File.join(dir, "build-payload.yml")
      File.write(matrix_path, MATRIX_FIXTURE)
      release = RegistrySpecRelease.new("https://api.test/releases/1", "v#{version}")
      client = FakeRegistryClient.new(release: release, shards: [])
      def client.release_for_tag(_repo, _tag)
        raise Octokit::NotFound
      end
      updater = described_class.new(client: client,
                                    env: { "TEBAKO_VERSION" => version,
                                           "REGISTRY_PATH" => File.join(dir, "r.yaml"),
                                           "MATRIX_PATH" => matrix_path })
      expect { updater.run }
        .to raise_error(RegistryUpdate::RegistryUpdateError, /no release found for tag v9\.9\.9/)
    end
  end

  it "fails named when the release carries no shards" do
    expect { render([]) }
      .to raise_error(RegistryUpdate::RegistryUpdateError, /carries no \.manifest\.json shards/)
  end
end

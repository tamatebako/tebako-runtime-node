# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of the Tebako project.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "json"
require "net/http"
require "uri"
require "yaml"

# The feedstock's release-shape model (spec 00 §10 — SSOT flow, never a
# second hand-authored copy): the two release-time tools
# (tools/audit_release.rb, tools/registry_update.rb) read the expected
# (flavor × platform) matrix FROM the build workflow's own matrix block
# (the owner of what gets built) and the version pins FROM Tebakofile
# (the owner of every version/digest literal). Both readers fail closed:
# a shape they do not recognize is a named error, never a guess.
module Feedstock
  class FeedstockError < StandardError; end

  # A candidate release that one of the two upstream dists has not
  # published yet (a 404 on its SHASUMS256.txt). Upstream LAG, not a
  # defect: the monitor holds the current pin and reports the candidate
  # by name instead of failing the daily run — a monitor that cannot
  # distinguish "upstream is late" from "upstream is broken" goes red
  # every day until the dists agree, which teaches everyone to ignore it.
  class UpstreamMissing < FeedstockError; end

  REPO_ROOT = File.expand_path("../..", __dir__).freeze
  RECIPE_BASENAME = "Tebakofile"
  MATRIX_RELPATH = ".github/workflows/build-payload.yml"

  # One platform leg of the build matrix: the spec 03 triplet (the
  # registry row key), the release-asset platform (the asset-name
  # segment), and the exe suffix — the platform's three spellings, paired
  # by the workflow matrix (their single owner in this repo).
  PlatformLeg = Struct.new(:triplet, :asset_platform, :exe_suffix)

  module_function

  def recipe_path(env = ENV)
    env["RECIPE_PATH"] || File.join(REPO_ROOT, RECIPE_BASENAME)
  end

  def matrix_path(env = ENV)
    env["MATRIX_PATH"] || File.join(REPO_ROOT, MATRIX_RELPATH)
  end

  def recipe(env = ENV)
    data = YAML.load_file(recipe_path(env))
    unless data.is_a?(Hash) && data["flavors"].is_a?(Hash) && data["runtime"].is_a?(Hash)
      raise FeedstockError, "NAMED FAILURE: #{recipe_path(env)} carries no flavors:/runtime: blocks — not a runtime recipe"
    end

    data
  end

  # The wrapper line the pairs build against (the release tag's bare
  # version — the tag IS the tebako product line).
  def wrapper_tebako(env = ENV)
    line = recipe(env).fetch("runtime")["wrapper_tebako"]
    return line if line.is_a?(String) && !line.empty?

    raise FeedstockError, "NAMED FAILURE: #{recipe_path(env)} runtime.wrapper_tebako missing"
  end

  # The flavor's published upstream version (Tebakofile's
  # flavors.<flavor>.upstream.version — the version pin's single owner).
  def flavor_version(flavor, env = ENV)
    version = recipe(env).dig("flavors", flavor, "upstream", "version")
    return version.to_s if version

    raise FeedstockError,
          "NAMED FAILURE: #{recipe_path(env)} carries no flavors.#{flavor}.upstream.version"
  end

  # The build legs' flavor axis, flowed from the build workflow's matrix
  # (the owner of what gets built). A matrix moved to include:-style (or
  # otherwise unrecognizable) is a named refusal.
  def matrix_flavors(env = ENV)
    flavors = matrix_block(env)["flavor"]
    return flavors if flavors.is_a?(Array) && flavors.all? { |f| f.is_a?(String) } && !flavors.empty?

    raise FeedstockError,
          "NAMED FAILURE: #{matrix_path(env)} build matrix carries no plain `flavor:` list — " \
          "the release tools read the leg set from it"
  end

  # The build legs' platforms, flowed from the build workflow's matrix as
  # PlatformLeg rows (triplet + asset_platform + exe_suffix, paired there
  # and nowhere else). A platform row missing any spelling is a named
  # refusal.
  def matrix_platforms(env = ENV)
    rows = matrix_block(env)["platform"]
    unless rows.is_a?(Array) && !rows.empty?
      raise FeedstockError,
            "NAMED FAILURE: #{matrix_path(env)} build matrix carries no plain `platform:` list — " \
            "the release tools read the leg set from it"
    end

    rows.map do |row|
      triplet = row.is_a?(Hash) && row["triplet"]
      asset = row.is_a?(Hash) && row["asset_platform"]
      suffix = row.is_a?(Hash) && row["exe_suffix"]
      unless triplet.is_a?(String) && asset.is_a?(String) && suffix.is_a?(String)
        raise FeedstockError,
              "NAMED FAILURE: #{matrix_path(env)} build matrix platform row lacks " \
              "triplet/asset_platform/exe_suffix: #{row.inspect}"
      end

      PlatformLeg.new(triplet, asset, suffix)
    end
  end

  # The flavor's distribution identity (Tebakofile's
  # flavors.<flavor>.implementation — tebako#716's language segment of the
  # runtime pair's name; the registry row's implementation key).
  def flavor_implementation(flavor, env = ENV)
    implementation = recipe(env).dig("flavors", flavor, "implementation")
    return implementation if implementation.is_a?(String) && implementation.match?(/\A[a-z0-9]+\z/)

    raise FeedstockError,
          "NAMED FAILURE: #{recipe_path(env)} carries no flavors.#{flavor}.implementation " \
          "(a dash-free [a-z0-9]+ segment) — the pair's name composes it"
  end

  # The spec 13 release-asset stem grammar over recipe-owned values —
  # tebako-runtime-<line>-<implementation>-<ver>-<asset-platform>
  # (tebako#716's language segment is the flavor's implementation;
  # tools/pins.rb and tools/build compose the same grammar).
  def runtime_stem(flavor, asset_platform, env = ENV)
    "tebako-runtime-#{wrapper_tebako(env)}-#{flavor_implementation(flavor, env)}" \
      "-#{flavor_version(flavor, env)}-#{asset_platform}"
  end

  # The write-once names one leg owns (spec 13 §2a): the pair (wrapper
  # exe + env image), each asset's .sha256 sidecar, and the package's
  # .manifest.json shard.
  def leg_asset_names(flavor, leg, env = ENV)
    stem = runtime_stem(flavor, leg.asset_platform, env)
    exe = "#{stem}#{leg.exe_suffix}"
    # The blksum sidecar and its own .sha256 are SERVED names (spec 39 §3):
    # the lazy mount verifies the sidecar against the row's pin before the
    # first range read, and delta has nothing to compare without it
    # (tebako#868).
    [exe, "#{exe}.sha256",
     "#{stem}.tfs", "#{stem}.tfs.sha256",
     "#{stem}.tfs.blksum.json", "#{stem}.tfs.blksum.json.sha256",
     "#{stem}.manifest.json"]
  end

  # Every leg's write-once names across the whole build matrix.
  def expected_asset_names(env = ENV)
    matrix_flavors(env).product(matrix_platforms(env)).flat_map do |flavor, leg|
      leg_asset_names(flavor, leg, env)
    end.sort
  end

  def matrix_block(env = ENV)
    workflow = YAML.load_file(matrix_path(env))
    block = workflow.is_a?(Hash) && workflow.dig("jobs", "build", "strategy", "matrix")
    return block if block.is_a?(Hash)

    raise FeedstockError,
          "NAMED FAILURE: #{matrix_path(env)} carries no jobs.build.strategy.matrix block — " \
          "the release tools read the leg set from it"
  end
  # The node release monitor (propose-bump shape): checks nodejs.org for
  # a newer release on the pinned major line and rewrites Tebakofile's
  # flavor sources to it with fresh SHASUMS256.txt digests — official
  # dists plus the unofficial-builds musl legs. Never crosses major
  # lines (the line pin is an owner decision), never writes a partial
  # file (every new digest resolves before the first byte moves), and
  # the version anchor is url-derived (`node-v<ver>-…`), never a bare
  # `version:` key — the Tebakofile's tools pins carry their own
  # version: keys and must never be caught by a bump.
  module ReleaseMonitor
    OFFICIAL_DIST = "https://nodejs.org/dist"
    UNOFFICIAL_DIST = "https://unofficial-builds.nodejs.org/download/release"

    module_function

    def check_and_bump(recipe_path = File.join(REPO_ROOT, RECIPE_BASENAME))
      body = File.read(recipe_path)
      current = current_version(body)
      candidates = newer_on_line(current)
      return { action: "current", current: current } if candidates.empty?

      # Walk the line newest-first and take the newest release BOTH dists
      # can serve in full. A candidate whose SHASUMS 404s, or whose
      # SHASUMS lacks one of the recipe's own assets (the unofficial
      # musl legs routinely lag the official dists), is a HOLD for that
      # candidate — never a partial rewrite, never a dead-end failure.
      held = []
      candidates.each do |candidate|
        digests = begin
          shasums_for(candidate)
        rescue UpstreamMissing => e
          held << { "candidate" => candidate, "missing" => [e.message] }
          next
        end
        missing = uncovered(body, current, candidate, digests)
        unless missing.empty?
          held << { "candidate" => candidate, "missing" => missing }
          next
        end
        updated, touched = rewrite(body, current, candidate, digests)
        File.write(recipe_path, updated)
        return { action: "bump", current: current, candidate: candidate, sources: touched }
      end
      { action: "hold", current: current, newest: candidates.first, held: held }
    end

    # Every source asset the recipe names, version-substituted to the
    # candidate — the completeness set a candidate's SHASUMS must cover.
    def pending_assets(body, current, candidate)
      body.scan(/node-v#{Regexp.escape(current)}-([^"'\s]+)/).flatten.map do |suffix|
        "node-v#{candidate}-#{suffix}"
      end.uniq
    end

    # The candidate's uncovered assets, in recipe order (empty = complete).
    def uncovered(body, current, candidate, digests)
      pending_assets(body, current, candidate).reject { |name| digests.key?(name) }
    end

    def current_version(body)
      body[/node-v(\d+\.\d+\.\d+)-/, 1] ||
        raise(FeedstockError, "NAMED FAILURE: no node-v<version>- source url in Tebakofile — the url anchor is gone")
    end

    def parse_shasums(text)
      text.each_line.each_with_object({}) do |line, map|
        digest, name = line.split
        map[name] = digest if digest && name
      end
    end

    def rewrite(body, current, candidate, digests)
      pending = nil
      touched = 0
      # The url-line match is the FULL authored grammar (url-key +
      # https + the two upstream hosts), anchored — never a substring
      # scan of a url-bearing line: a comment mentioning nodejs.org
      # must never arm a rewrite.
      source_url = /^\s*url:\s*"https:\/\/(?:unofficial-builds\.)?nodejs\.org\//
      lines = body.each_line.map do |line|
        if line =~ source_url && line.include?("node-v#{current}-")
          pending = line[/node-v#{Regexp.escape(current)}-[^\"']+/, 0]
                     &.gsub("v#{current}", "v#{candidate}")
          touched += 1
          next line.gsub("v#{current}", "v#{candidate}")
        end
        if pending && (digest_line = line.match(/^\s*sha256: "([0-9a-f]{64})"/))
          digest = digests.fetch(pending) do
            raise FeedstockError,
                  "NAMED FAILURE: v#{candidate} carries no SHASUMS256.txt entry for #{pending} — upstream layout changed"
          end
          pending = nil
          next line.sub(digest_line[1], digest)
        end
        line
      end
      joined = lines.join
      joined = joined.sub("version: \"#{current}\"", "version: \"#{candidate}\"")
      [joined, touched]
    end

    # --- the network edge (kept last: everything above is specable) ---

    def newest_on_line(current)
      newer_on_line(current).first
    end

    # The line's releases NEWER than `current`, newest-first, stable
    # releases only (a prerelease is never a bump candidate).
    def newer_on_line(current)
      index = http_get_json("#{OFFICIAL_DIST}/index.json")
      prefix = "v#{current.split('.').first}."
      index.filter_map do |entry|
        version = entry["version"].to_s
        next unless version.start_with?(prefix)

        version = version.sub(/\Av/, "")
        next unless version.match?(/\A\d+\.\d+\.\d+\z/)
        next unless Gem::Version.new(version) > Gem::Version.new(current)

        version
      end.sort_by { |version| Gem::Version.new(version) }.reverse
    end

    def shasums_for(version)
      %W[#{OFFICIAL_DIST}/v#{version}/SHASUMS256.txt
         #{UNOFFICIAL_DIST}/v#{version}/SHASUMS256.txt]
        .flat_map { |url| parse_shasums(http_get(url)) }.reduce(:merge)
    end

    def http_get(url)
      uri = URI.parse(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri))
      end
      # 404 is upstream LAG on a per-version artifact (the caller decides
      # whether that candidate is skippable); every other non-2xx is the
      # dead-upstream failure the monitor never guesses past.
      raise UpstreamMissing, "GET #{url} answered 404 — not published upstream" if response.code == "404"
      unless response.is_a?(Net::HTTPSuccess)
        raise FeedstockError, "NAMED FAILURE: GET #{url} answered #{response.code} — the monitor never guesses past a dead upstream"
      end

      response.body
    end

    def http_get_json(url)
      require "json"
      JSON.parse(http_get(url))
    end
  end
end

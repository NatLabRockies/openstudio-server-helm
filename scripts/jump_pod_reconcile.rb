#!/usr/bin/env ruby
# Runs INSIDE the jump pod (piped via `kubectl exec -i ... ruby - ARGS`).
# Compares expected batches (parametric_space_Batch<N>.json in the staged project)
# with analyses already on the server.
#
# Usage: ruby - MODE SERVER_URI PROJECT_DIR
#   MODE=reconcile  delete empty stub analyses, move already-submitted batch files
#                   to PROJECT_DIR/submitted/ so the rake glob only sees remaining ones
#   MODE=check      report expected vs created; exit 1 if any batch is missing/empty
#
# A batch is matched to an analysis only when its name/display_name contains the
# project name AND "Batch<N>" (N not preceded/followed by a digit or letter).
# Status lookup errors abort the run without deleting anything.
require 'json'
require 'net/http'
require 'fileutils'

mode, base, dir, project = ARGV
abort 'usage: MODE SERVER_URI PROJECT_DIR PROJECT_NAME' unless mode && base && dir && project

def http_json(method, url)
  uri = URI(url)
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req['Accept'] = 'application/json'
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 120) { |h| h.request(req) }
  raise "#{method} #{url} -> HTTP #{res.code}" unless res.code.to_i < 300
  res.body.to_s.empty? ? nil : JSON.parse(res.body)
end

def datapoint_count(base, id)
  st = http_json('get', "#{base}/analyses/#{id}/status.json")
  dps = st.is_a?(Hash) && st['analysis'] ? st['analysis']['data_points'] : nil
  raise "unexpected status payload for #{id}" unless dps.is_a?(Array)
  dps.size
end

def batch_of(f)
  File.basename(f)[/Batch_?(\d+)(?!\d)/i, 1]&.to_i
end

expected = {}
[dir, File.join(dir, 'submitted')].each do |d|
  Dir.glob(File.join(d, 'parametric_space*Batch*.json')).each do |f|
    n = batch_of(f)
    expected[n] = f if n
  end
end
abort "No parametric_space batch files found in #{dir}" if expected.empty?

analyses = http_json('get', "#{base}/analyses.json") || []
by_batch = Hash.new { |h, k| h[k] = [] }
analyses.each do |a|
  label = [a['name'], a['display_name']].compact.join(' ')
  next unless label.include?(project)
  n = label[/(?<![A-Za-z0-9])Batch_?(\d+)(?![0-9A-Za-z])/i, 1]
  by_batch[n.to_i] << a if n
end

done = []
stubs = []
expected.each_key do |n|
  by_batch[n].each do |a|
    (datapoint_count(base, a['_id']) > 0 ? done : stubs) << [n, a]
  end
end
done_batches = done.map(&:first).uniq
stub_only = stubs.map(&:first).uniq - done_batches
missing = expected.keys - done_batches

puts "expected=#{expected.size} complete=#{done_batches.size} empty_stub_only=#{stub_only.size} missing=#{missing.size}"

if mode == 'reconcile'
  stubs.each do |n, a|
    puts "deleting empty stub analysis #{a['_id']} (batch #{n})"
    http_json('delete', "#{base}/analyses/#{a['_id']}.json")
  end
  FileUtils.mkdir_p(File.join(dir, 'submitted'))
  done_batches.each do |n|
    Dir.glob(File.join(dir, '{parametric_space,measure_space}*Batch*.json')).each do |f|
      next unless batch_of(f) == n
      dest = File.join(dir, 'submitted', File.basename(f))
      File.exist?(dest) ? FileUtils.rm_f(f) : FileUtils.mv(f, dest)
    end
  end
  puts "remaining batches to submit: #{(expected.keys - done_batches).size}"
else
  unless missing.empty?
    puts "MISSING_BATCHES: #{missing.sort.join(',')}"
    exit 1
  end
  puts 'All expected batches present.'
end

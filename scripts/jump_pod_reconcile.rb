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
# A batch is matched to an analysis when the analysis name/display_name contains
# "Batch<N>" (case-insensitive, N not followed by a digit).
require 'json'
require 'net/http'
require 'fileutils'

mode, base, dir = ARGV
abort 'usage: MODE SERVER_URI PROJECT_DIR' unless mode && base && dir

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
  dps.is_a?(Array) ? dps.size : 0
rescue StandardError
  0
end

expected = {}
[dir, File.join(dir, 'submitted')].each do |d|
  Dir.glob(File.join(d, 'parametric_space*Batch*.json')).each do |f|
    n = File.basename(f)[/Batch_?(\d+)/i, 1]
    expected[n.to_i] = f if n
  end
end
abort "No parametric_space batch files found in #{dir}" if expected.empty?

analyses = http_json('get', "#{base}/analyses.json") || []
by_batch = Hash.new { |h, k| h[k] = [] }
analyses.each do |a|
  label = [a['name'], a['display_name']].compact.join(' ')
  n = label[/Batch_?(\d+)(?!\d)/i, 1]
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
    f = expected[n]
    next if File.dirname(f).end_with?('submitted')
    FileUtils.mv(f, File.join(dir, 'submitted', File.basename(f)))
    # matching measure space file, if any
    Dir.glob(File.join(dir, "measure_space*Batch*#{n}.json")).each do |m|
      FileUtils.mv(m, File.join(dir, 'submitted', File.basename(m)))
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

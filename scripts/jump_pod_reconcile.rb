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
# project name (bounded by non-alphanumerics) AND "Batch<N>" (N not preceded/followed
# by a digit or letter). An analysis is only DELETED if the project name is directly
# followed by the Batch<N> token (so "foo" never deletes "foo-old" analyses), it has
# 0 data points, is not running, and is older than STUB_MIN_AGE seconds (default 900).
# Any young/running empty analysis aborts reconcile (it may still be populating).
# Status lookup errors abort the run without deleting anything.
require 'json'
require 'net/http'
require 'fileutils'
require 'time'

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

RUNNING_STATES = %w[started queued running pending].freeze
STUB_MIN_AGE = (ENV['STUB_MIN_AGE'] || 900).to_i

# Returns [data_point_count, analysis_status_string].
def analysis_state(base, id)
  st = http_json('get', "#{base}/analyses/#{id}/status.json")
  an = st.is_a?(Hash) ? st['analysis'] : nil
  dps = an ? an['data_points'] : nil
  raise "unexpected status payload for #{id}" unless dps.is_a?(Array)
  [dps.size, an['status'].to_s.downcase]
end

def age_seconds(a)
  ts = a['created_at'] || a['updated_at']
  ts ? Time.now - Time.parse(ts.to_s) : nil
rescue ArgumentError
  nil
end

# Full batch id as used in analysis names, e.g. "Batch6593_proposed_training".
def batch_id_of(f)
  File.basename(f)[/(Batch_?\d+[A-Za-z0-9_]*?)\.json\z/i, 1]
end

# Reconciliation key: the full batch id (so Batch123 and Batch123_x stay distinct).
def key_of(f)
  id = batch_id_of(f)
  id ? id.downcase.sub(/\Abatch_?/, 'batch') : nil
end

def batch_of(f)
  File.basename(f)[/Batch_?(\d+)(?!\d)/i, 1]&.to_i
end

expected = {}
[dir, File.join(dir, 'submitted')].each do |d|
  Dir.glob(File.join(d, 'parametric_space*Batch*.json')).each do |f|
    k = key_of(f)
    expected[k] = f if k
  end
end
abort "No parametric_space batch files found in #{dir}" if expected.empty?

# The server names analyses "<BatchId>_<UTC timestamp>" without the project name, so also match
# on the exact full batch id (number + suffix) followed by that timestamp.
by_number = expected.keys.group_by { |k| k[/\d+/].to_i }
id_re = /(?<![A-Za-z0-9])(Batch_?\d+[A-Za-z0-9_]*?)_\d{4}_\d{2}_\d{2}_\d{2}_\d{2}_\d{2}_UTC(?![A-Za-z0-9])/i

analyses = http_json('get', "#{base}/analyses.json") || []
proj_re = /(?<![A-Za-z0-9])#{Regexp.escape(project)}(?![A-Za-z0-9])/
strict_re = /(?<![A-Za-z0-9])#{Regexp.escape(project)}[\s_.:\-]*(?:parametric_space|measure_space)?[\s_.:\-]*Batch_?\d+(?![A-Za-z0-9])/i
by_batch = Hash.new { |h, k| h[k] = [] }
analyses.each do |a|
  label = [a['name'], a['display_name']].compact.join(' ')
  m = label.match(id_re)
  by_id = m && (k = m[1].downcase.sub(/\Abatch_?/, 'batch')) && expected.key?(k) ? k : nil
  next unless label =~ proj_re || by_id
  key = by_id
  unless key
    num = label[/(?<![A-Za-z0-9])Batch_?(\d+)(?![0-9A-Za-z])/i, 1]
    cands = num && by_number[num.to_i]
    key = cands.first if cands && cands.size == 1 # ambiguous numbers are never matched
  end
  by_batch[key] << [a, (label =~ strict_re || by_id) ? true : false] if key
end

done = []
stubs = []
in_flight = []
expected.each_key do |n|
  by_batch[n].each do |a, strict|
    count, status = analysis_state(base, a['_id'])
    if count > 0
      done << [n, a]
    else
      age = age_seconds(a)
      if RUNNING_STATES.include?(status) || age.nil? || age < STUB_MIN_AGE
        in_flight << [n, a]
      end
      stubs << [n, a, strict]
    end
  end
end
done_batches = done.map(&:first).uniq
stub_batches = stubs.map(&:first).uniq
stub_only = stub_batches - done_batches
missing = expected.keys - done_batches

puts "expected=#{expected.size} complete=#{done_batches.size} empty_stub_only=#{stub_only.size} missing=#{missing.size}"

if mode == 'reconcile'
  unless in_flight.empty?
    ids = in_flight.map { |n, a| "#{a['_id']}(batch #{n})" }.join(', ')
    abort "Empty analyses that may still be populating (running or younger than #{STUB_MIN_AGE}s): #{ids}. " \
          'Wait and retry; not deleting or submitting.'
  end
  stubs.each do |n, a, strict|
    unless strict
      puts "NOT deleting empty analysis #{a['_id']} (batch #{n}): name does not match '#{project}' + #{n} exactly"
      next
    end
    puts "deleting empty stub analysis #{a['_id']} (batch #{n})"
    http_json('delete', "#{base}/analyses/#{a['_id']}.json")
  end
  FileUtils.mkdir_p(File.join(dir, 'submitted'))
  done_batches.each do |n|
    Dir.glob(File.join(dir, '{parametric_space,measure_space}*Batch*.json')).each do |f|
      next unless key_of(f) == n
      dest = File.join(dir, 'submitted', File.basename(f))
      File.exist?(dest) ? FileUtils.rm_f(f) : FileUtils.mv(f, dest)
    end
  end
  puts "remaining batches to submit: #{(expected.keys - done_batches).size}"
else
  empty = stubs.map { |n, a, _| "#{a['_id']}(batch #{n})" }
  puts "EMPTY_ANALYSES: #{empty.join(',')}" unless empty.empty?
  puts "MISSING_BATCHES: #{missing.sort.join(',')}" unless missing.empty?
  exit 1 unless missing.empty? && empty.empty?
  puts 'All expected batches present.'
end

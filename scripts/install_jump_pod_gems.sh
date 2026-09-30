#!/usr/bin/env bash
# Short-term manual/script gem install for jump_pod container.
# Run after deploying jump_pod: installs missing CLI gems into the
# running container's /opt/openstudio/gems/ directory.
#
# Use: kubectl exec deploy/jump-pod -n openstudio-server -- bash /tmp/install_jump_pod_gems.sh (kubectl cp scripts/install_jump_pod_gems.sh first)

set -euo pipefail

# 1) rubyzip (usually quick; confirmed working in web/worker containers)
echo "Installing rubyzip..."
GEM_HOME=/opt/openstudio/gems GEM_PATH=/opt/openstudio/gems:/opt/openstudio/gems/bundler/gems \
  /usr/local/bin/ruby -S gem install rubyzip -v 2.3.2 --install-dir /opt/openstudio/gems

# 2) openstudio-analysis (from PAT / openstudio-server gems)
#    This may take 2-5 minutes. If it times out, install from host source
#    or use a pre-built custom image instead.
echo "Installing openstudio-analysis (may take 2-5 min)..."
GEM_HOME=/opt/openstudio/gems GEM_PATH=/opt/openstudio/gems:/opt/openstudio/gems/bundler/gems \
  /usr/local/bin/ruby -S gem install openstudio-analysis -v 1.5.2 --install-dir /opt/openstudio/gems || {
    echo "openstudio-analysis install failed or timed out."
    echo "Fallback: copy from host source or use pre-built image."
    echo "Example host copy:"
    echo "  kubectl cp /Users/achapin/OpenStudio/OpenStudio-server/gems/openstudio-analysis/ <pod>:/opt/openstudio/gems/gems/"
    exit 1
  }

# 3) Verify key binaries/gems are available after install
echo "=== Post-install verification ==="
/opt/openstudio/bin/openstudio_meta --help 2>/dev/null | head -3 || echo "WARNING: openstudio_meta not working"
GEM_HOME=/opt/openstudio/gems GEM_PATH=/opt/openstudio/gems /usr/local/bin/ruby -e \
  'require "zip"; puts "rubyzip: OK"' 2>/dev/null || echo "WARNING: rubyzip not loadable"
GEM_HOME=/opt/openstudio/gems GEM_PATH=/opt/openstudio/gems /usr/local/bin/ruby -e \
  'require "rubygems"; spec = Gem::Specification.find_all_by_name("openstudio-analysis").first; puts spec ? "openstudio-analysis: OK (" + spec.gem_dir + ")" : "openstudio-analysis: MISSING"' 2>/dev/null

echo "=== Install complete ==="

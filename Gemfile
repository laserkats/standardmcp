source "https://rubygems.org"

gemspec

# standardapi 9.x isn't on RubyGems yet (it has 7.1.4), so pin a commit.
# This pins standardapi PR 108 (attribute-schemas), which builds on master's ACL
# `wheres`. Bump the ref deliberately when standardmcp needs newer standardapi
# changes, and drop this line once 9.0 is released (the gemspec's >= 9.0.0 then applies).
gem "standardapi", git: "https://github.com/waratuman/standardapi.git", ref: "ed41c596b8f7ead7cc20cc1c3a78038e887c9baa"

# Pin minitest to 5.x until Rails is compatible with minitest 6.0's API changes
gem 'minitest', '~> 5.0'

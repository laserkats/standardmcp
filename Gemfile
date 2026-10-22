source "https://rubygems.org"

gemspec

# standardapi 9.x isn't on RubyGems yet (it has 7.1.4), so pin a commit.
# This pins standardapi PR 109 (query-write-read-schemas), stacked on PR 108
# (attribute-schemas), which builds on master's ACL `wheres`. Bump the ref
# deliberately when standardmcp needs newer standardapi changes, and drop this
# line once 9.0 is released (the gemspec's >= 9.0.0 then applies).
gem "standardapi", git: "https://github.com/waratuman/standardapi.git", ref: "1da51f24cc80a7b4bba6afabce24cb64cc7fb9fc"

# Pin minitest to 5.x until Rails is compatible with minitest 6.0's API changes
gem 'minitest', '~> 5.0'

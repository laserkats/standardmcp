source "https://rubygems.org"

gemspec

# standardapi 9.x isn't on RubyGems yet (it has 7.1.4), so pin a master commit.
# Bump the ref deliberately when standardmcp needs newer standardapi changes,
# and drop this line once 9.0 is released (the gemspec's >= 9.0.0 then applies).
gem "standardapi", git: "https://github.com/waratuman/standardapi.git", ref: "6222967041a6b0c243e1e8aec33dfc2eb13167aa"

# Pin minitest to 5.x until Rails is compatible with minitest 6.0's API changes
gem 'minitest', '~> 5.0'

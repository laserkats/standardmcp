FactoryBot.define do

  factory :account do
    name   { Faker::Company.name }
    status { 'active' }
    notes  { Faker::Lorem.sentence }
  end

  factory :property do
    account
    name        { Faker::Address.community }
    size        { Kernel.rand(1000..100000) }
    description { Faker::Lorem.paragraph }
  end

  factory :photo do
    property
    format        { %w(jpg png tiff).sample }
    caption       { Faker::Lorem.sentence }
    internal_path { "/srv/photos/#{SecureRandom.hex(4)}" }
  end

end

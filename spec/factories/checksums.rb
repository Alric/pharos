FactoryBot.define do
  factory :checksum do
    algorithm { 'sha256' }
    datetime { Time.zone.now.to_s }
    digest { SecureRandom.hex }
  end
end

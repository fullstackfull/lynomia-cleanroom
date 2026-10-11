require 'rails_helper'

# D-12: two reports for one recipient, processed at the same moment, must resolve deterministically.
#
# This is the one scenario the rest of the suite cannot express. Transactional fixtures put every example on a
# single connection inside a single transaction, where two threads cannot contend for a row lock at all: the
# second would either see the first's uncommitted write or block for ever. So this file opts out of them, uses a
# connection per thread, and cleans up after itself.
#
# What it proves is that the outcome is decided by the forward-only rule rather than by commit order. Without
# `with_lock` in CampaignRecipient#record_outcome! both threads would read `sent`, both would consider their own
# report an advance, and whichever committed last would win -- so a `delivered` report landing a millisecond
# after a `read` report would demote the recipient, and the campaign's read count would lose it.
RSpec.describe CampaignRecipient, type: :model do
  self.use_transactional_tests = false

  # Each round gets its own account so a leftover row from a failed round cannot affect the next.
  let(:reported_at) { Time.zone.at(1_760_000_000) }

  def build_recipient
    account = Account.create!(name: "concurrency-#{SecureRandom.hex(4)}")
    channel = Channel::WebWidget.create!(account: account, website_url: 'https://concurrency.example')
    inbox = Inbox.create!(account: account, name: 'concurrency', channel: channel)
    campaign = Campaign.create!(account: account, inbox: inbox, title: 'c', message: 'c',
                                campaign_type: :one_off, scheduled_at: 1.hour.ago)
    described_class.create!(
      account: account, campaign: campaign, inbox: inbox, contact: Contact.create!(account: account, name: 'c'),
      status: :sent, sent_at: reported_at, source_id: "wamid.concurrency-#{SecureRandom.hex(4)}"
    )
  end

  # Both reports are applied through freshly loaded instances, because an ActiveRecord object is not safe to
  # share between threads -- which is also true of the two webhook workers this is standing in for.
  def apply_concurrently(recipient_id, first, second)
    [first, second].map do |state|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.find(recipient_id).record_outcome!(state, reported_at: reported_at)
        end
      end
    end.each(&:join)
  end

  after do
    Account.where("name LIKE 'concurrency-%'").find_each(&:destroy!)
  end

  # Ten rounds in each order. One round can pass by luck; a demotion that only happens when the threads
  # interleave a particular way would show up across twenty.
  it 'ends at the furthest state reported, in either order, every time' do
    outcomes = []

    10.times do
      recipient = build_recipient
      apply_concurrently(recipient.id, 'delivered', 'read')
      outcomes << recipient.reload.attributes.values_at('status', 'delivered_at', 'read_at')
    end
    10.times do
      recipient = build_recipient
      apply_concurrently(recipient.id, 'read', 'delivered')
      outcomes << recipient.reload.attributes.values_at('status', 'delivered_at', 'read_at')
    end

    expect(outcomes.map(&:first).uniq).to eq(['read'])
    # Both timestamps are set whichever thread won the lock first: each report stamps its own event even when it
    # does not move the state, which is what lets P8 count a read-before-delivered recipient as delivered.
    expect(outcomes).to all(satisfy { |(_status, delivered_at, read_at)| delivered_at.present? && read_at.present? })
  end

  # A delivery racing a failure. Meta sent both, so which event happened first is not something this end knows;
  # what must never happen is a row that carries both timestamps, because the analytics read the two
  # independently and would count that one recipient as delivered AND as failed.
  it 'resolves a delivery racing a failure to exactly one of the two' do
    results = Array.new(10) do
      recipient = build_recipient
      apply_concurrently(recipient.id, 'delivered', 'failed')
      recipient.reload.attributes.values_at('status', 'delivered_at', 'failed_at')
    end

    expect(results.map(&:first).uniq).to all(be_in(%w[delivered failed]))
    results.each do |status, delivered_at, failed_at|
      if status == 'delivered'
        expect([delivered_at.present?, failed_at]).to eq([true, nil])
      else
        # The failure took the lock first and is terminal: the later delivery report stamps nothing.
        expect([failed_at.present?, delivered_at]).to eq([true, nil])
      end
    end
  end

  # The rule the race above depends on, stated on its own so a regression names itself.
  it 'treats a failure as terminal' do
    recipient = build_recipient
    recipient.record_outcome!('failed', reported_at: reported_at, error_code: '131026')

    expect(recipient.record_outcome!('delivered', reported_at: reported_at + 60)).to be(false)
    expect(recipient.record_outcome!('read', reported_at: reported_at + 120)).to be(false)
    expect(recipient.reload).to have_attributes(status: 'failed', delivered_at: nil, read_at: nil)
  end
end

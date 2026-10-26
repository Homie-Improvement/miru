# frozen_string_literal: true

# Delivers mail like ActionMailer::MailDeliveryJob, and retries a mail whose
# invoice timestamp write was refused because a Timekeeping handoff is in
# progress. The refusal is raised before delivery, so a retry sends the mail
# once, after the handoff ends, instead of dropping it.
class BillingFencedMailDeliveryJob < ActionMailer::MailDeliveryJob
  # A handoff can pause billing for minutes, so the wait grows with each
  # attempt rather than using the 5 second hint given to HTTP callers.
  HANDOFF_RETRY_ATTEMPTS = 25

  retry_on Timekeeping::BillingFence::OwnershipMoving, wait: :polynomially_longer, attempts: HANDOFF_RETRY_ATTEMPTS
end

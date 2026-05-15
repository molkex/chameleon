# Apple Escalation Channels for the 5.4 / 2.3.12 Blocker

Catalogue of every channel we can use to push the App Store v1.0.26 rejection
forward, ranked by effectiveness and speed. The story so far is in incident
`2026-05-15-app-review-5-4-account-misclassification`. Build 75/76 in
TestFlight, App Store stuck on Guideline 5.4 (Legal — VPN Apps) misclassifying
our ИП Organization account as "individual."

## Already attempted

1. **Resolution Center reply** on round-6 submission `7891c82c` — D-U-N-S
   argument with all account identifiers. The next reviewer raised the same
   flag.

2. **App Review Board appeal** via `developer.apple.com/contact → Request
   Support for an App Rejection or Removal → I believe my app follows the
   guidelines → App Rejection`. Issues checked: 5.4 and 2.3.12. Apple
   confirmation page received; outcome by email to molkex@icloud.com.
   Submitted 2026-05-15 ~15:35 MSK. Typical SLA 1-5 business days.

3. **Re-submission** as round 7 (`8578a42d`) — rejected the same way,
   Apple's exact words: "The issues we previously identified still need
   your attention."

## Tier 1 — strongest channels not yet used

### Phone call from App Review

The Resolution Center page on every rejected submission has a
"Request a call to discuss your app's review" link. Apple schedules a
**30-minute call with a senior reviewer** within 3-5 business days. This
is one of the most effective channels because:
  - It's a synchronous conversation — we can walk through D-U-N-S +
    enrollment evidence and not be subject to "another reviewer sees the
    same flag" loop
  - Senior reviewers have authority to overrule routine 5.4 flags
  - It's the official, Apple-documented escalation path

When to use: **immediately after Ruben if he doesn't respond within 24h.**

### Personal Apple contact — Ruben (Developer Support)

Ruben was the Apple Developer Support agent who processed our individual →
organization enrollment in April (enrollment ID SS264955P7). He has
context on our account history and can:
  - Verify the Organization classification from inside Apple's tools
  - Flag the misclassification to App Review on our behalf
  - Tell us if something changed on Apple's side after our enrollment

Email drafts stored at:
  - `.local/drafts/email-ruben-5-4-misclassification.txt` (English)
  - `.local/drafts/email-ruben-5-4-misclassification-ru.txt` (Russian — preferred for personal contacts)

When to use: **first move.** Drafted 2026-05-15.

### Developer Program Membership / Account Holder Verification

This is a separate team from App Review — they own the enrollment record
itself. Path:
  developer.apple.com/contact → Membership and Account →
  (Account Holder Verification / Membership Inquiry / etc.)

They can pull the actual classification record for Team 99W3C374T2 and
either confirm Organization or explain how it got re-classified. Different
team from App Review, so a different lens on the same problem.

When to use: in parallel with Ruben, or if Ruben can't help.

## Tier 2 — escalation if Tier 1 stalls

### Apple Executive Relations (Tim Cook letter)

`tcook@apple.com` or `appleceo@apple.com`. The CEO doesn't read them
personally, but Executive Relations team triages every message and they
have the authority to push App Review and the Membership team on stuck
cases. Effective for clearly-misclassified-account situations like ours.
Tone: factual, concise, "we've exhausted normal channels, please escalate."

When to use: if Tier 1 yields nothing within ~7 days.

### Apple Developer Forums

Public post at forums.developer.apple.com in the App Review category,
tagged with the specific Guideline. Apple-Frameworks-Engineer or App
Review team members do read these and occasionally respond.

Pros: public visibility can shame-fix; other devs may share workarounds.
Cons: slow, not guaranteed, somewhat public-airing of our problem.

When to use: as a low-priority parallel channel.

## Tier 3 — not recommended

### Public social media

Twitter/X posts tagging @AppStore @AppleSupport @tim_cook etc.
Pros: very fast visibility if anything goes viral.
Cons: for a VPN app, attracting public attention is the wrong kind. Apple
specifically dislikes "complaining publicly" and it can hurt your relation
with the App Review team. Hard pass for VPN-app context.

### Legal / regulatory routes

Russia: Apple has had reduced presence and altered support since 2022.
Not realistic to expect a Russian legal threat to move them.
EU: DMA-related complaints exist for monopoly behaviour, but our
classification issue isn't a monopoly issue — won't be a path here.

## Recommended sequence

1. **Day 0 (today):** Email Ruben (Russian draft). Wait 24h.
2. **Day 1:** If Ruben silent, click "Request a call to discuss your
   app's review" on the rejection page → Apple calls within 3-5 days.
   In parallel, submit Membership / Account-Holder-Verification ticket.
3. **Day 5-7:** If Appeal Board hasn't responded and no other channel
   produced movement → Tim Cook letter.
4. **Day 10+:** If still stuck → consider re-enrollment via ООО / LLC
   (last resort — many months and significant business work).

## Identifiers (for any conversation with Apple)

  - Team ID: 99W3C374T2
  - D-U-N-S Number: 94245265
  - Enrollment ID: SS264955P7 (processed by Ruben, 2026-04-21)
  - Legal entity on file: Tkachuk Maksim Nikolaevich, IP
  - App: MadFrog VPN, Apple ID 6761008632
  - Last rejected submission: 8578a42d-1161-4395-9f95-1c8a93a33118 (round 7)
  - Penultimate rejected submission (with our reply preserved):
    7891c82c-c58c-47f7-9833-8d0ec60ecd46 (round 6)
  - Outstanding App Review Board appeal: filed 2026-05-15 via
    developer.apple.com/contact

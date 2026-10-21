# The voice's permissions

Maggie's voice needs two things from macOS:

- **Microphone**, to hear you.
- **Speech Recognition**, for the Mac itself to hear "hey Maggie" and "unmute" while
  the voice is muted or paused. Nothing leaves the Mac for this; it is Apple's
  on-device recognition. Without it the voice still works, but only a click brings it
  back from muted or paused.

Both are asked for the first time the voice starts. Settings › Voice › Permissions shows
what macOS has answered for each, and what to do about it.

## Why a prompt doesn't come back

macOS shows its prompt once, the first time an app asks, and never again on its own. A
prompt declined, or dismissed with Escape, leaves the answer at "not allowed" until you
turn it on in System Settings or the answer is reset. An update can't ask again either.

Earlier versions asked for speech recognition only the first time the voice was muted
or paused, which could be a quarter of an hour after you had walked away; the prompt
then sat unanswered, or was dismissed with the next keypress. Now the voice asks when
it starts, while you are there.

## Why an update can lose the answer

macOS keeps each answer against the app's bundle ID *and* its code signature. The
official Maggie is signed with a Developer ID certificate, which is the same from
release to release, so updates keep the answers. A build signed any other way under the
same bundle ID, such as one installed with `fork/install.sh` over the official app,
doesn't match them: macOS asks again, or holds the old answer against the new build
until it is reset. (A locally built Maggie for testing should be installed as its own
app: `APP_NAME="Maggie Dev" BUNDLE_ID=com.marciosete.maggie.dev fork/install.sh`.)

## Getting it back

In Maggie, Settings › Voice › Permissions:

- **Request Access** appears while macOS hasn't asked, and shows its prompt.
- **Open System Settings** appears once macOS has said no, and opens Privacy & Security
  at the right pane, where Maggie can be turned on.
- **Ask Again** clears macOS's answer for Maggie and asks afresh. Use it when a prompt
  was declined, or when the permission is shown as allowed but "hey Maggie" is never
  heard, which means the answer was given to an earlier signature of the app.

The same by hand, in Terminal:

```sh
tccutil reset SpeechRecognition com.marciosete.maggie
tccutil reset Microphone com.marciosete.maggie
```

Then start the voice again; macOS asks. (For Maggie Dev the bundle ID is
`com.marciosete.maggie.dev`.) The System Settings panes are Privacy & Security ›
Speech Recognition and Privacy & Security › Microphone.

On macOS before 26, the Mac hears the wake phrases through Apple's older recogniser,
which also needs Dictation turned on in System Settings › Keyboard.

## What the voice announces

While the voice is on, a watched session (one you opened or instructed by voice, or
asked it to watch; every session, with "Announce every session that finishes or needs
me" on) is announced when it needs you, finishes, fails or ends. The news comes from the
sidebar's lights and, sooner, from Claude Code's own hook events, which Maggie's plugin
hands the app the moment they happen: a permission prompt with what it asks for, the
end of a turn with the agent's last words, a turn that died on a rate limit or an
outage, and the session exiting. A permission prompt's event comes about six seconds
after the prompt appears, if you haven't typed in that session meanwhile; the light
usually says so first, and the voice says each piece of news once.

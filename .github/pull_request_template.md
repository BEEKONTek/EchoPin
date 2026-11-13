## What this changes

Say what the change does and why. Link the issue it closes, if any:
Closes #

## How it was tested

List the commands you ran and what they printed, and any phones or
desktops the change was tried on (model and OS version).

    flutter analyze
    flutter test
    (cd server && tool/test.sh)

## Checklist

- [ ] `flutter analyze` is clean and `dart format` makes no change
- [ ] A test covers the change (a fix includes the test that reproduced the bug)
- [ ] Documentation is updated where the behaviour changed
- [ ] `docs/PROTOCOL.md` is updated if a wire format changed
- [ ] `CHANGELOG.md` has an entry
- [ ] Nothing location-like is recorded or sent, and the app still works with no server

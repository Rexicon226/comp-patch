Unofficial recreation of TMNF Competitive Patch v1.5.1.

## Background

I do not believe in a world where we rely on security/competitive patches
being closed source in order to protect against cheating. The collective
benefit of software being open source far outweights the few hour
speedbump of decompiling and understanding how the patch works. If
security through obscurity is the best the Competitive Patch can offer,
then it is lacking.

So I provide a re-implementation of the inner workings of the Competitive
Patch in Zig, after a few days of careful poking and proding with Ghidra
and objdump.

## How it works!

The `TMCompPatch.dll` uses the DirectInput proxy to load and initializes
under the Windows loader lock, like the original 1.5.1 patch. It then validates
its image base, the PE metadata, and all of the hook sites.

Then 5 DirectInput methods are hooked: `Acquire`, `Unacquire`, `Poll`,
`GetDeviceState`, and `GetDeviceData`. Alternate Method uses Raw Input
for keyboards and HID controllers, translating input back into DirectInput
compatible state and buffered events.

Game hooks detect race starts, restarts, action-history updates, completion,
and replay serialization.

Input transitions are timestamped using the current race time. The patch then
reconciles those transitions with the game's action history, retainig events
associated with steering, acceleration, braking, and respawning.

The patch also records:

- elapsed wall-clock time
- completion date
- input device identifiers
- whether Alternate Method was active
- some indicators for Wine, debugger, and known speedhack being active

When the race finishes, the patch:

1. Derives an encryption key using XXH64, game data, action history, and a
fixed hash.
2. Generates a random 16-byte IV.
3. Builds the competition record and encrypts it with AES-128-CFB.
4. Sets the game's replay-validation entries to
   `TmForeverCompPatch.2.11.26(1.6)`.
5. Wraps the record in PIKS framing.
6. Inserts it into replay chunk `0x0304F001`.

The record is appended only when the replay being saved matches the completed
live race. TrackMania itself skips this custom chunk during playback, so I'm
assuming the external verifier extracts and interprets it.

### Other 

- Does some changes to the window title and in-game message labels.
- Applies a randomized -20...+20 adjustment to one signed 24-bit game value
when its state permits.
- Applies some minor game-code behaviour modifications.

## Bugs found in the original patch

Well, this is why I do not like having stuff closed source and supressed.
It helps nobody in the end.

There were a few out-of-bounds, around the Raw HID button handling
and HID capability ranges being insufficiently validated.

I believe the input caches used could become stale during hotplug, focus, or
acquiore/unacquire transitions.

I don't really know why, but the intiialization performed a lot of work
while under the loader lock, which is a pretty terrible idea, and hook writes
were non-atomic and didn't perform ifences.

ASLR is a bit of a funny story, as v1.5.1 doesn't have it. v1.5.2 *does* enable
ASLR, but their replay identitiy code wasn't very compatible with it. They
set the preferred base to `0x10000000` in their compiler flags and set
`DYNAMIC_BASE`. When Windows loads the binary, it chooses a random base
and applied the `HIGHLOW` relocations, but then the Patch would hash
the relocated executable memory. So whenever it chose a different base,
it would result in a different hash, which is itself used as the seed for
this replay key derivation.

v1.5.3 fixed this by just setting a preferred base again, `0x28760000`,
removing the `DYNAMIC_BASE`, which let them get this stable hash `0x45AF3775`.

This is silly though! If a bit more effort was applied, they could have instead
done a few different things:

- hash code normalized back to its preferred base
- exclude the relocation-related bytes
- hash the on-disk image

When looking at the v1.5.1 patch, which is also static, there is a fixed code
hash, so we are trivially able to enable ASLR on it. We never hash any of the
relocated machine code.

Then there's the encryption that is used for the replay, AES-128-CFB. This
is a bit of a wacky mode, which I don't see very often. It is not an 
authenticated mode!

Now, It is honestly beyond my understanding why we would be encrypting anything
when it comes to offline cheating-preventing. The key is completely visible
and trivial to recover. What need is there to keep information confidential
when writing records that'll be sent to a verifier anyways?

With that said, they could have at least chosen a mode like AES-128-GCM, to
at least make it authenticated and disallow 3rd-party modification. Or, could
just not encrypt anything, do like a BLAKE3 or SHA256 based transcript hash
of the events, and be done with it.

## Conclusion

As long as the Competitive Patch uses offline attestation (which, to be clear,
I do really believe it should), it will always be possible to trivially keep
up an unofficial rewrite like this one, and I believe someone should. If this
pushes the team behind the patch to concretely improve the effectiveness of
the patch, then great.

I've playing TMNF for a very long time, and I do not believe there are major
cheating issues abound in the game. Once in a while someone will decide to
apply a lot of effort to the problem, and they could absolutely succeed. 

The bottom line is that, when doing offline preventing, the key is deterrence
rather than making it impossible. (The worst-case is just unsolvable, a cheater
could run in a stealth Windows VM with a slightly modified NTDLL layer that
controls how timestamps are reported, and there's just nothing to be done
about it.)

But that's alright. A Competitive Patch can go a long way in preventing most
simple cheats, which is the important part. It should be a steep uphill battle,
not impossible, as making it impossible sacrifies everyone else who is playing
fairly. 

There are absolutely steps that the Competitive Patch can take to greatly
increase its security without changing the surface it runs on. Performing
more detailed correlation work between different hardware timers and frame
counters, input pattern analysis from many user replays, etc.

I have figured out the v1.5.2 and v1.5.3 versions of the patch, those
integrate with the CoreMod and rely on it for some address translation,
hilarious ASLR issue in v1.5.2 that was quickly patched in v1.5.3. These
aren't as interesting to publish, maybe I'll put them into another branch.
They rely on CoreMod, include a few more checks around live race objects, etc.

Absolutely no AI, slopping, or clanking used. I like ethical anarchy.
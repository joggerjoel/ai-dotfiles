# What to gitignore vs commit

A responsive audit produces two kinds of artifact, and they get opposite treatment.

**`.audit/` is scratch — never commit it.** It holds raw captures and probe output
for one run: full-resolution PNGs at four viewports for every route, plus the JSON
the probe returned. It is regenerated from scratch on every audit, it is large, and
it is worthless to anyone who wasn't running that specific audit.

**The published viewer is a deliverable — commit it.** The curated before/after pairs
under the app's `public/` dir are what people actually look at and link to. They are
downsampled, hand-picked, and meant to outlive the run.

## The rule

```gitignore
# Responsive audit work product — regenerated per run, never shared
.audit/
```

That single line is all you need. The published viewer lives under `public/` and the
E2E specs under `tests/`, so both are already tracked by default — you don't add
anything to un-ignore them.

## Which is which

| Path                                        | Treatment          | Why                                |
| ------------------------------------------- | ------------------ | ---------------------------------- |
| `.audit/screenshots/`                       | ignored            | raw captures, regenerated each run |
| `.audit/screenshots/after/`                 | ignored            | same, post-fix                     |
| `.audit/findings.json`                      | ignored            | raw probe output                   |
| `.audit/findings-after.json`                | ignored            | same, post-fix                     |
| `.audit/AUDIT.md`                           | ignored by default | see below                          |
| `apps/<app>/public/_dev/audits/<slug>/`     | **committed**      | the shareable viewer               |
| `apps/<app>/public/_dev/audits/<slug>/img/` | **committed**      | curated before/after pairs         |
| `apps/<app>/tests/e2e/responsive/`          | **committed**      | regression coverage                |

## The one judgment call

`.audit/AUDIT.md` is the written audit doc. It's ignored by default because it sits
inside `.audit/`, but unlike the PNGs it is small, readable, and often the most
durable output of the whole exercise.

If you want to keep it in history, move it out of the scratch dir rather than
un-ignoring it — a negation pattern inside an ignored directory is easy to
misread later:

```
# Prefer this
docs/audits/<slug>.md        # tracked, lives outside .audit/

# Over this
.audit/
!.audit/AUDIT.md             # works, but the intent is opaque at a glance
```

## Before you commit the viewer

The screenshots go into a **public** directory. Check them for anything that
shouldn't ship: authenticated fixture data, real customer names, internal-only
routes, staging banners, or tokens visible in a URL bar. Audits are usually run
against seeded data, but "usually" is doing a lot of work in a directory that
gets served to the internet.

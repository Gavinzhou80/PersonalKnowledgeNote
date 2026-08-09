# Source Document publication is atomic through a durable intent, not a filesystem transaction

Source Document publication spans two stores that cannot share one physical transaction: SQLite records and managed artifact files on disk. The application can terminate at any persistence or file-publication point. We decided that Local Library provides observable all-or-nothing publication through a durable hidden publication intent plus a single database visibility point: the staged artifact is prepared and verified first, the hidden intent is committed, the artifact is moved into place with an atomic same-volume directory rename, and only then does one visibility transaction make the document readable. Startup recovery reconciles every surviving intent against the filesystem (missing artifact rolls back, verified artifact completes, invalid artifact quarantines), so a half-published Source Document is unreachable by readers.

## Considered Options

- Treating final-artifact file existence as the publication authority: rejected because partial writes, crashes mid-rename, and orphaned files cannot be distinguished from complete publication without a durable record of intent.
- Cross-store two-phase commit: rejected because SQLite and the filesystem offer no shared transaction coordinator, and emulating one would recreate the intent journal with more machinery.

## Consequences

- All publication and recovery code treats the durable intent, not file presence, as the authority; readers never see hidden document rows.
- Staging and final artifacts must stay on the same filesystem volume so rename remains atomic.
- Every new publication stage must fit the intent/visibility/recovery protocol rather than inventing its own visibility rules.

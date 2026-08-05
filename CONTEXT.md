# Personal Knowledge Note

This context describes how external reading material becomes durable, traceable knowledge inside a personal local library.

## Language

**Document Import**:
The one-time process that turns an Original Source into a managed Source Document.
_Avoid_: Document Ingestion, capture pipeline

**Import Task**:
A staged, recoverable attempt to perform Document Import. It may be pending, running, cancelled, or failed, but it is not a Source Document until the minimum readable and locatable result is published atomically.
_Avoid_: draft document, partial Source Document

**Import Preview**:
A temporary read-only view of a staged Source Artifact while its Import Task is still running. It cannot create durable annotations, notes, translations, or source positions.
_Avoid_: Source Document, partial document, editable preview

**Import Issue**:
A localized uncertainty or degradation discovered during Document Import that does not make the Source Document unusable, such as uncertain reading order, heading hierarchy, media association, or source positioning.
_Avoid_: import failure, warning log

**Original Source**:
An external webpage URL or PDF file from which a Source Document is created. A Source Document may retain multiple Original Sources as provenance, but they are not the authority for later reading and annotation.
_Avoid_: live document, canonical document

**Source Artifact**:
The immutable local HTML package or PDF file captured and managed by Document Import. It remains available for reading and annotation independently of the Original Source.
_Avoid_: Original Source, temporary download, cache file

**Source Document**:
An immutable, managed local document composed of a Source Artifact, Source Blocks, Source Structure, and Source Evidence. It is the authority for reading, quotations, structure, and source positions after import.
_Avoid_: Imported Document, local copy, cached document

**Document Profile**:
The user-editable library information associated with a Source Document, including corrected display metadata, confirmed Primary Language, folder placement, favorites, and reading state.
_Avoid_: Source Document, source metadata

**Primary Language**:
The single natural language that best represents a Source Document for reading and translation. Document Import suggests it, while the user-confirmed value belongs to the Document Profile.
_Avoid_: interface language, translation target language, per-block language

**Content Fingerprint**:
A deterministic identity derived from imported content and used to recognize an existing Source Document independently of its title, URL, filename, or file path.
_Avoid_: document name, source URL, semantic similarity

**Source Block**:
A stable, ordered occurrence of content in a Source Document that retains its original position. Identical text appearing in different source positions remains distinct Source Blocks.
_Avoid_: chunk, fragment, extracted paragraph

**Text Block**:
A Source Block whose primary content is natural language, with a role such as heading, paragraph, list item, quotation, caption, footnote, or reference entry.
_Avoid_: generic paragraph, text chunk

**Code Block**:
A Source Block whose primary content is code, a command, or other preformatted text that is preserved rather than translated as natural language.
_Avoid_: Text Block, formula

**Media Block**:
A Source Block whose primary content is a figure, table, or standalone formula and whose original visual form must be preserved.
_Avoid_: attachment, text placeholder

**Canonical Text**:
The normalized plain-text representation of a Text Block or Code Block used for quotation, search, translation, and content verification.
_Avoid_: rendered text, raw HTML, attributed string

**Inline Markup**:
The limited semantic information embedded within Canonical Text, such as emphasis, links, citations, inline code, and inline formulas, without carrying source-specific presentation details.
_Avoid_: arbitrary HTML, PDF styling, rich text document

**Source Evidence**:
Format-specific facts that connect a Source Block to its location in the immutable source artifact. It preserves the strongest evidence available without forcing webpages and PDFs into one coordinate system.
_Avoid_: universal coordinate, Source Anchor

**Source Structure**:
The immutable hierarchy, inferred reading order, and Source Relations identified during Document Import from headings, bookmarks, and layout evidence.
_Avoid_: editable outline, note structure

**Source Relation**:
An immutable relationship observed between Source Blocks during Document Import, such as a caption describing a figure or table.
_Avoid_: knowledge link, user association, note relation

**Reading Outline**:
The user-editable hierarchy used to navigate a Source Document and organize its reading notes. It begins from Source Structure and references Source Blocks without changing them.
_Avoid_: Source Structure, table of contents copy

**Reading Order**:
The user-correctable sequence in which Source Blocks are read, translated, and composed. It begins from Source Structure while leaving Source Block identity and Source Evidence unchanged.
_Avoid_: Source Structure, PDF object order

# C4 Model: Document Matters and Evidence-Grounded Briefs

## Scope

This model describes the proposed first release: a private, cited **Document brief** and a user-maintained document-matter timeline. It does not include free-form chat or a vector database.

## C1 — System context

```mermaid
flowchart LR
    user["Person: authenticated ZaimuTomo user"]
    app["Software system: ZaimuTomo\nPhoenix personal-finance application"]
    db[("Database: PostgreSQL\nsource text, facts, matters, relationships, briefs")]
    storage["ZaimuTomo-hosted/private object storage\noriginal document bytes"]
    ocr["Third-party system: Mistral\nOCR"]
    llm["Configured LLM provider\ninterpreter + explainer"]
    langfuse["Third-party system: Langfuse\nprompt/tracing observability"]

    user -->|uploads, reviews, confirms, reads cited brief| app
    app -->|stores scoped metadata/evidence| db
    app -->|authenticated preview/download only| storage
    app -->|temporary document upload / OCR request| ocr
    app -->|bounded evidence pack / structured response| llm
    app -->|trace, prompt metadata, output observability| langfuse

    classDef thirdParty fill:#fdf4ff,stroke:#a21caf,stroke-width:2px,color:#701a75
    classDef zaimuTomoOwned fill:#ecfdf5,stroke:#059669,stroke-width:2px,color:#064e3b
    class ocr,llm,langfuse thirdParty
    class app,db,storage zaimuTomoOwned
```

**Legend:** purple nodes are third-party-operated services. Green nodes are
ZaimuTomo-owned components and data stores. The user is an external person
interacting with the application.

### Context decisions

1. The browser never gets raw database access, object-store credentials, or another user's evidence.
2. PostgreSQL owns app-facing source text, citations, matters, relationships, and brief state. Object storage owns original bytes.
3. LLM providers receive a bounded evidence pack, not the archive or an unrestricted SQL/search capability.
4. Langfuse is observability and prompt management. It is not the durable citation store.
5. The document brief is descriptive only. Accounting, tax claims, and payment actions retain their existing human-owned flows.

## C2 — Container model

```mermaid
flowchart TB
    subgraph client[User device]
      browser["Browser\nPhoenix LiveView client"]
    end

    subgraph apphost[ZaimuTomo Phoenix / BEAM]
      web["Router + authenticated LiveViews\ndocument detail, matter timeline"]
      processing["DocumentProcessing.OCRJob + Worker\nOCR, extraction, verification\n(:documents queue)"]
      intelworker["DocumentIntelligence.Worker\ninterpret, suggest, brief\n(:intelligence queue, fail-open)"]
      evidence["DocumentEvidence context\nOCR text, excerpts, FTS"]
      intelligence["DocumentIntelligence context\ninterpretation, retrieval, brief validation"]
      matters["Matters context\nuser-owned grouping and relationships"]
      llmclient["LLMClient + Langfuse\nstructured interpreter/explainer"]
    end

    postgres[("PostgreSQL")]
    objectstore["Private object storage"]
    ocr["Mistral OCR"]
    llm["Configured LLM backend"]
    langfuse["Langfuse"]

    browser -->|LiveView events/navigation| web
    web --> evidence
    web --> intelligence
    web --> matters
    processing -->|text in terminal transaction| evidence
    processing -->|enqueue in same transaction| intelworker
    intelworker --> intelligence
    intelworker --> matters
    evidence --> postgres
    intelligence --> postgres
    matters --> postgres
    intelligence --> llmclient
    llmclient --> llm
    llmclient --> langfuse
    processing --> ocr
    web -->|existing authenticated controller path| objectstore
```

## C3 — Component model

```mermaid
flowchart LR
    subgraph existing[Existing domains]
      documents["Documents\nscoped document lifecycle"]
      worker["DocumentProcessing.Worker\nOCR -> extraction -> verification"]
      review["Review\nhuman invoice review"]
      accounting["Accounting\njournal entries and tax claims"]
    end

    subgraph new[New document-intelligence domains]
      evidence["DocumentEvidence\nsource OCR body + deterministic excerpts + FTS"]
      interpretation["DocumentIntelligence\nversioned machine/user interpretation"]
      relation["Relationships\nconservative candidate suggestions"]
      matters["Matters\nfinancial matters, links, confirmation"]
      briefs["Briefs\nbounded evidence pack + cited structured brief"]
    end

    subgraph web[Authenticated UI]
      documentshow["DocumentLive.Show\ndraft interpretation + brief"]
      matterlive["MatterLive\ntimeline + confirmation"]
    end

    worker -->|text in terminal transaction| evidence
    worker -->|enqueues :intelligence job| interpretation
    interpretation --> relation
    evidence --> briefs
    relation --> matters
    matters --> briefs
    documents --> documentshow
    evidence --> documentshow
    interpretation --> documentshow
    briefs --> documentshow
    matters --> matterlive
    review -.->|does not receive side effects| interpretation
    accounting -.->|does not receive side effects| briefs
```

## Key flow — automatic document brief

```mermaid
sequenceDiagram
    participant Job as OCRJob + Worker
    participant OCR as Mistral OCR
    participant DB as PostgreSQL
    participant Intel as DocumentIntelligence.Worker
    participant Matters as Matters/Relationships
    participant LLM as Configured LLM
    participant User as Authenticated user

    Job->>OCR: original private document
    OCR-->>Job: OCR response (pages[].markdown)
    Job->>Job: extract + verify invoice (may fail for letters)
    Job->>DB: one transaction: extraction row (success or failed),<br/>document text + excerpts, enqueue :intelligence job
    Note over Job,Intel: the OCR job is done here, and nothing below can retry or fail it
    Intel->>DB: read scoped text
    Intel->>LLM: interpreter: source text, structured schema
    LLM-->>Intel: validated interpretation (or durable failed row)
    Intel->>Matters: suggest relationships from scoped evidence
    Intel->>DB: bounded scoped retrieval (links, identifiers, FTS)
    Intel->>LLM: explainer: evidence pack and output schema
    LLM-->>Intel: cited brief candidate
    Intel->>DB: validate all excerpt/document IDs, persist brief (ready or failed)
    User->>DB: opens DocumentLive.Show
    DB-->>User: labelled draft explanation, unknowns, citations
```

## Invariants

- All new public context functions accept `current_scope` first and return inaccessible entities as not found.
- A document link/relationship cannot cross `user_id` boundaries.
- The UI cannot render a material brief claim without a source excerpt citation.
- User corrections and confirmed/rejected links are preserved separately from machine output and take effective precedence.
- Source document deletion invalidates/removes derived evidence and current brief state; no citation can point at a deleted source.
- The explainer cannot execute a financial action. It only receives an evidence pack and returns a validated data structure.

## Future extensions, intentionally outside this model

- Guided questions reuse the same `Briefs` evidence-pack path.
- Free-form chat requires a separate interaction, persistence, safety, and evaluation design.
- Optional `pgvector` would sit beside FTS in PostgreSQL and return excerpt IDs into the same evidence-pack contract; it would not alter authorization or citation validation.

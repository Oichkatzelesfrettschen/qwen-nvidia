# Qwen3.5 4B Artifact Admission

The daily-model artifact is
`unsloth/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf` at repository revision
`e87f176479d0855a907a41277aca2f8ee7a09523`.

The Hugging Face resolver reports:

- byte size: `2740937888`;
- LFS SHA-256: `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4`;
- Xet object: `1d203c2196991da08bc5b191ab4727516f476f3167e3276f75a0c5257493aadb`;
  and
- byte-range support: enabled.

The laptop destination filesystem reports 1,719,344,570,368 free bytes before
download. The destination contains no complete or partial candidate artifact.

`remote/download-qwen35-4b-q4km.sh` pins the repository revision, writes only
to an `.part` path, resumes by byte range, rejects a partial file larger than
the published artifact, verifies the exact byte count and SHA-256, and renames
the file only after both checks pass. The script enforces CPU 0, absolute nice
19, and idle I/O priority.

---

Rename the conversations in the current Codex project. Only change conversation titles. Never touch the project name.

Rules:

- Date comes from the conversation's `createdAt`, converted to Asia/Shanghai. Do not use `updatedAt`.
- Format: `MMDD｜TYPE｜Topic`
- TYPE must be one of these. Use the English code by default. Use the Chinese label only if I ask for Chinese.
  FEA / 功能 = feature
  DES / 设计 = design
  FIX / 修复 = bug fix
  OPT / 优化 = optimization
  REL / 发布 = release
  EXP / 探索 = exploration
  DOC / 文档 = docs
  RES / 研究 = research
- Use one language for TYPE across all titles in a run. Never mix.
- Topic summarizes what the conversation is actually about. Do not repeat the project name.
- Keep titles short and specific. They show in the sidebar.
- If you cannot tell the topic, keep the original title. Do not guess.
- Change nothing else: not the project name, conversation content, project assignment, order, pin state, or archive state.

Examples (English, the default):

Before: Improve batch text display
After:  0903｜OPT｜Batch text display

Before: New feature discussion
After:  0901｜DES｜UI alignment check

Examples (Chinese, on request):

Before: 优化批次文字显示
After:  0903｜优化｜批次文字显示

Before: 提交代码到 GitHub
After:  0813｜发布｜提交代码到GitHub

Before making any change, output only a two-column table with this exact header:
\| Before | After |
Wait for my confirmation. After renaming, report only the results.

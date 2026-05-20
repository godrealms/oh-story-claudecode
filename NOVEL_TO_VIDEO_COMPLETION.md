# 小说转视频流水线 — 实施完成报告

## 已完成

5 个新 skill,共 ~80 commits 在 `novel-to-video` 分支。

### 新 skill 列表

| skill | 触发词 | 状态 |
|---|---|---|
| story-to-script | /story-to-script、转剧本 | ✅ 全部实现 |
| script-to-shot | /script-to-shot、分镜 | ✅ 全部实现 + JSON validator |
| shot-to-image | /shot-to-image、生镜头图 | ✅ 6 后端全部实现(gpt-image/mj/replicate/fal/comfy/prompt-only) |
| image-to-video | /image-to-video、图生视频 | ✅ 4 真后端实现(kling/jimeng/runway/prompt-only)+ 2 占位(sora/veo) |
| story-pipeline | /story-pipeline、拍短剧 | ✅ 6 闸门编排实现 |

### 与现有系统集成

- ✅ `marketplace.json` 注册 5 个新 plugin
- ✅ `/story` 路由表新增 5 个出口 + 关键词分发
- ✅ `story-long-write` 末尾加跨链跳转
- ✅ README.md + README_EN.md 更新

## 需要用户手动验证的 acceptance test

以下两个测试需要在 Claude Code 里跟 skill 交互,subagent 跑不了。请在合并前自己走一遍:

### Test 1: /story-pipeline 端到端(prompt-only 全跑)

```bash
mkdir -p /tmp/test-pipeline/{设定/角色,大纲,正文,追踪}
cat tests/fixtures/novel-sample-chapter.md > /tmp/test-pipeline/正文/第001章_雨夜.md
cat > /tmp/test-pipeline/设定/角色/沈栀.md <<'EOF'
# 沈栀
- 年龄:二十出头
- 外貌:长发及腰,左眉一道旧疤
EOF
cat > /tmp/test-pipeline/设定/角色/司长.md <<'EOF'
# 司长
- 年龄:五十岁
EOF

cd /tmp/test-pipeline
export IMG_BACKEND=prompt-only
export VIDEO_BACKEND=prompt-only
```

在 Claude Code 里输入: `/story-pipeline`

跟着 6 个 gate 走:
- gate-0:确认转第 1 章 / 1 章一集 / 竖屏 / 节奏优先
- gate-1 拍摄本完成 → 看产物 → 批"继续"
- gate-2 镜头表完成 → 跑 validator → 批"继续"
- gate-3 角色卡完成(prompt-only 模式无 .png,有 .card.json)→ 批"继续"
- gate-4 镜头图完成 → 看提示词文件 → 批"继续"
- gate-5 镜头视频完成 → 看提示词视频文件 → 批"继续"
- gate-6 交付包 → 看 README.md / 字幕脚本.txt / _manifest.json

验证 `.pipeline.state.json` 中所有 gate-0 到 gate-6 是 approved。

清理:`rm -rf /tmp/test-pipeline`

### Test 2: 单 skill 独立使用不写 state.json

```bash
mkdir -p /tmp/test-standalone/短剧/第001集
cp tests/fixtures/expected-shotlist.json /tmp/test-standalone/短剧/第001集/镜头表.json
cd /tmp/test-standalone
```

在 Claude Code 里输入: `/shot-to-image 短剧/第001集/镜头表.json`

验证产物落到 `短剧/第001集/镜头图/`,**不**生成 `.pipeline.state.json`(因为没在 pipeline 里跑)。

清理:`rm -rf /tmp/test-standalone`

## 合并建议

通过 acceptance test 后:
1. 删除本文件:`rm NOVEL_TO_VIDEO_COMPLETION.md`
2. 合并:`git merge novel-to-video --no-ff -m "feat: add novel-to-video pipeline (5 skills)"`
3. 或者发 PR:`gh pr create --base main --head novel-to-video`

## 知识债务(留待 future hygiene pass)

实施过程中发现的 minor issues(非阻塞,可累积清理):
1. `cost-table.md`:可加 character card 1-time overhead 行
2. `prompt-construction.md`:可加 worked example
3. backend-cheatsheet pricing:可补充 standard/turbo 模式区分
4. character_card.sh:`shot_id` 作为角色名语义有点别扭(可在 Plan 4 后续 task 改成 --id)
5. 一些 reference 文档可以双向 cross-link 更完整

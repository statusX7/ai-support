'use strict';

// 只在固定 AnythingLLM 容器内由受管脚本调用，不是网络接口。
const fs = require('fs');
const {createRequire} = require('module');
process.chdir('/app/server');
const componentRequire = createRequire('/app/server/package.json');
const output = process.stdout.write.bind(process.stdout);
for (const name of ['log', 'info', 'warn', 'error', 'debug']) console[name] = () => {};

(async () => {
  const action = process.argv[2] || 'observe';
  const slug = process.argv[3];
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(slug || '')) throw Error('参数无效');
  const dotenv = componentRequire('dotenv');
  const diskEnv = fs.existsSync('/app/server/.env') ? dotenv.parse(fs.readFileSync('/app/server/.env')) : {};
  dotenv.config({path: '/app/server/.env'});
  const {NativeEmbedder} = componentRequire('./utils/EmbeddingEngines/native');
  const {SystemSettings} = componentRequire('./models/systemSettings');
  const prisma = componentRequire('./utils/prisma');
  try {
    const model = NativeEmbedder._getEmbeddingModel();
    const info = NativeEmbedder.supportedModels[model];
    if (!info) throw Error('组件静默回退了未知模型');
    if (action === 'configure-chunks') {
      const size = Number(process.argv[4]), overlap = Number(process.argv[5]);
      if (!Number.isInteger(size) || size < 1 || size > info.embeddingMaxChunkLength || !Number.isInteger(overlap) || overlap < 0 || overlap >= size) throw Error('分块参数无效');
      await SystemSettings.updateSettings({text_splitter_chunk_size: size, text_splitter_chunk_overlap: overlap});
    } else if (action !== 'observe' && action !== 'probe') throw Error('动作无效');
    const configured = process.env.EMBEDDING_MODEL_PREF;
    if (configured && configured !== model) throw Error('组件静默回退了未知模型');
    const sizeSetting = typeof SystemSettings.get === 'function' ? await SystemSettings.get({label: 'text_splitter_chunk_size'}) : null;
    const overlapSetting = typeof SystemSettings.get === 'function' ? await SystemSettings.get({label: 'text_splitter_chunk_overlap'}) : null;
    const size = sizeSetting?.value ?? await SystemSettings.getValueOrFallback({label: 'text_splitter_chunk_size'});
    const overlap = overlapSetting?.value ?? await SystemSettings.getValueOrFallback({label: 'text_splitter_chunk_overlap'}, 20);
    const workspace = await prisma.workspaces.findUnique({where: {slug}, select: {id: true}});
    const foreign = await prisma.workspace_documents.count({where: workspace ? {workspaceId: {not: workspace.id}} : {}});
    const result = {engine: process.env.EMBEDDING_ENGINE || 'native', model,
      // Compose 的受管投影始终设置当前模型；只有组件自身持久配置才算用户既有显式选择。
      explicit_model: Boolean(diskEnv.EMBEDDING_MODEL_PREF),
      chunk_size: Math.min(Number(size || info.embeddingMaxChunkLength), info.embeddingMaxChunkLength),
      chunk_overlap: Number(overlap), explicit_chunk_size: Boolean(sizeSetting),
      passage_prefix: info.chunkPrefix, query_prefix: info.queryPrefix,
      component_version: componentRequire('./package.json').version,
      foreign_documents: foreign, workspace_documents: workspace ? await prisma.workspace_documents.count({where: {workspaceId: workspace.id}}) : 0,
      workspace_exists: Boolean(workspace)};
    if (action === 'probe') {
      const embedder = new NativeEmbedder();
      const vector = await embedder.embedTextInput('中文资料检索校验');
      if (!Array.isArray(vector) || vector.length < 1 || !vector.every(Number.isFinite)) throw Error('模型没有返回有效向量');
      result.probe_dimensions = vector.length;
    }
    output(JSON.stringify(result) + '\n');
  } finally { await prisma.$disconnect(); }
})().catch(() => { process.stderr.write('知识组件检查未完成，请检查固定版本、模型及资料权限。\n'); process.exitCode = 1; });

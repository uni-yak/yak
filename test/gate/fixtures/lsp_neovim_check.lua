-- 通过真实缓冲事件驱动内置 LSP 客户端，不转发或手写协议帧。
local server = assert(vim.env.YAK_NVIM_SERVER)
local evidence = assert(vim.env.YAK_NVIM_EVIDENCE)
local root = vim.fs.joinpath(evidence, 'workspace')
local file = vim.fs.joinpath(root, 'Yak 中 文.yak')
local original = '//中😀'
local bad_again = original .. 'x'
local fixed = 'function f(): void {}\n'
local report = { status = 'failed', server = server, editor = vim.version().major .. '.' .. vim.version().minor
  .. '.' .. vim.version().patch, publications = {}, edits = {} }
local server_exit, client
local function equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(message .. '\n预期：' .. vim.inspect(expected) .. '\n实际：' .. vim.inspect(actual), 2)
  end
end
local function await(check, message)
  assert(vim.wait(20000, check, 10), '等待超时：' .. message)
end
local function disk_contents()
  local fd = assert(io.open(file, 'rb'))
  local contents = assert(fd:read('*a'))
  assert(fd:close())
  return contents
end
local function eof(column)
  local point = { line = 0, character = column }
  return { code = 'E1018', severity = 1, source = 'yak', message = 'Yak 词法诊断 E1018',
    range = { start = point, ['end'] = point } }
end
local function published(index)
  await(function() return #report.publications >= index end, '诊断通知 ' .. index)
  local packet = report.publications[index]
  equal(report.uri, packet.uri, '诊断 URI 不匹配')
  return packet.diagnostics
end
local function shown(buf, bytes)
  local values = vim.tbl_map(function(item)
    return { code = item.code, severity = item.severity, source = item.source, message = item.message,
      range = { item.lnum, item.col, item.end_lnum, item.end_col } }
  end, vim.diagnostic.get(buf))
  equal({ { code = 'E1018', severity = vim.diagnostic.severity.ERROR, source = 'yak',
    message = 'Yak 词法诊断 E1018', range = { 0, bytes, 0, bytes } } }, values, '编辑器字节列或错误信息不匹配')
  return values
end
local function change(buf, src)
  -- 未换行原文件保留 noendofline，末尾空行显式表达修正所需的 LF。
  vim.api.nvim_buf_set_lines(buf, 0, -1, true, vim.split(src, '\n', { plain = true }))
  assert(vim.bo[buf].modified, '修改必须保留在未保存缓冲中')
  equal(original, disk_contents(), '修改不得改变磁盘文件')
end

local function run()
  vim.lsp.set_log_level('trace')
  report.trace = vim.lsp.log.get_filename()
  vim.o.fileformats = 'unix'
  vim.cmd.edit(vim.fn.fnameescape(file))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = 'yak'
  equal({ original }, vim.api.nvim_buf_get_lines(buf, 0, -1, true), '原始缓冲内容')
  equal(false, vim.bo[buf].endofline, '原始缓冲没有末尾 LF')
  equal('unix', vim.bo[buf].fileformat, '测试使用 LF')
  report.uri = vim.uri_from_bufnr(buf)
  local edits = vim.api.nvim_create_autocmd('LspNotify', {
    callback = function(args)
      local data = args.data
      if client and data.client_id == client.id and data.method == 'textDocument/didChange' then
        report.edits[#report.edits + 1] = vim.deepcopy(data.params)
      end
    end,
  })
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  -- 明确请求 UTF-16，以逐项对照协议字符列与编辑器字节列。
  capabilities.general.positionEncodings = { 'utf-16' }
  local id = assert(vim.lsp.start({ name = 'yak', cmd = { server }, root_dir = root,
    capabilities = capabilities,
    handlers = {
      ['textDocument/publishDiagnostics'] = function(err, result, ctx, config)
        assert(not err and result)
        report.publications[#report.publications + 1] = vim.deepcopy(result)
        vim.lsp.handlers['textDocument/publishDiagnostics'](err, result, ctx, config)
      end,
    },
    on_exit = function(code, signal) server_exit = { code = code, signal = signal } end,
  }, { bufnr = buf }), '未启动标准客户端')
  client = assert(vim.lsp.get_client_by_id(id))
  await(function() return client.initialized end, '握手')
  report.capabilities = client.server_capabilities
  equal({ openClose = true, change = 2 }, report.capabilities.textDocumentSync, '使用增量同步')
  equal('utf-16', report.capabilities.positionEncoding, '服务接受客户端的 UTF-16 编码')
  equal(true, report.capabilities.definitionProvider, '提供同文件定义')
  equal(true, report.capabilities.hoverProvider, '提供同版悬停')
  equal({ triggerCharacters = { '.', ':' } }, report.capabilities.completionProvider, '注册成员和模块的补全触发字符')
  equal({ legend = { tokenTypes = { 'keyword', 'string', 'number', 'operator' }, tokenModifiers = {} }, full = true },
    report.capabilities.semanticTokensProvider, '仅完整语义记号')
  equal(true, report.capabilities.documentSymbolProvider, '提供文档符号')
  equal(true, report.capabilities.foldingRangeProvider, '提供按行折叠')
  equal('utf-16', client.offset_encoding, '客户端使用协商的 UTF-16')
  equal({ eof(5) }, published(1), '打开文件的 UTF-16 诊断')
  report.open = shown(buf, #original)
  change(buf, fixed)
  equal({}, published(2), '未保存修正应清空协议诊断')
  equal({}, vim.diagnostic.get(buf), '未保存修正应清空编辑器诊断')
  report.unsavedFix = { modified = vim.bo[buf].modified, diskUnchanged = true }
  change(buf, bad_again)
  equal({ eof(6) }, published(3), '再次改坏的 UTF-16 诊断')
  report.unsavedError = shown(buf, #bad_again)
  -- 删除编辑器缓冲而不保存，确认服务实际回发清空，而非只清除编辑器状态。
  vim.api.nvim_buf_delete(buf, { force = true })
  equal({}, published(4), '关闭应清空协议诊断')
  equal(original, disk_contents(), '关闭不得改变磁盘文件')
  report.close = { attached = vim.lsp.buf_is_attached(buf, id), diskUnchanged = true }
  equal(false, report.close.attached, '关闭后不再附着缓冲')
  equal(4, #report.publications, '每次事件只发布一次')
  equal(2, #report.edits, '每次未保存修改各发送一个增量通知')
  local previous_version = -1
  for _, edit in ipairs(report.edits) do
    equal(report.uri, edit.textDocument.uri, '增量通知使用当前文档 URI')
    assert(edit.textDocument.version > previous_version, '增量通知版本必须递增')
    previous_version = edit.textDocument.version
    assert(#edit.contentChanges > 0, '增量通知必须包含修改')
    for _, patch in ipairs(edit.contentChanges) do
      assert(type(patch.range) == 'table' and type(patch.text) == 'string', '客户端必须发送带范围的修改')
    end
  end
  vim.api.nvim_del_autocmd(edits)
  client:stop()
  await(function() return server_exit ~= nil end, '服务退出')
  equal(0, server_exit.code, '正常关闭后的退出码')
  equal(0, server_exit.signal, '服务未被强制结束')
  report.status = 'passed'
end

local ok, reason = xpcall(run, debug.traceback)
if not ok then
  report.error = reason
  if client and not server_exit then
    client:stop()
    vim.wait(3000, function() return server_exit ~= nil end, 10)
  end
end
report.serverExit = server_exit
assert(vim.fn.writefile({ vim.json.encode(report) }, vim.fs.joinpath(evidence, 'editor.json')) == 0)
if ok then
  vim.cmd('qa!')
else
  io.stderr:write(reason .. '\n')
  vim.cmd('cquit 1')
end

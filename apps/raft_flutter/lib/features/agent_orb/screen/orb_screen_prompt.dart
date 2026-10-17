/// The 【屏幕】 section of the orb's prompt: the page you arrive on comes with
/// its screen, and `screen_action` acts on it. Kept apart from the rest of the
/// prompt (orb_prompt.dart adds it as one block).
const orbScreenPrompt =
    '【屏幕】每个页面都带着它的屏幕：navigate、open_item、describe_page 返回的 screen 里，text 是页面上看得到的字，actions 是能做的事（id、名字、角色、do 里是能做的动作）。'
    '要在页面上做事（点按钮、切标签、打开一行、往输入框填字、滚动）就用 screen_action；先读 screen 再做，只用读到的 id，不要猜 id，也不要用上一页的 id。'
    '返回 error 并带 snapshot，是屏幕变了：照新的 snapshot 再选一次。念名字，不念 id。\n';

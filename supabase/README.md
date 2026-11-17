# 匿名遊玩統計（Supabase）設定步驟

1. Supabase 後台 → **SQL Editor** → 貼上 `setup.sql` 全部內容 → Run。
2. **Authentication → Sign In / Providers**：關閉「Allow new users to sign up」（只有你能登入後台）。
3. **Authentication → Users → Add user**：建立你的管理員帳號（勾選 Auto Confirm User，用長一點的密碼）。
4. 回到 SQL Editor 執行（email 換成你的）：
   ```sql
   insert into public.admins (user_id) select id from auth.users where email = '你的email' on conflict do nothing;
   ```
5. **Project Settings → API**（或 API Keys）複製 **Project URL** 和 **publishable / anon key**，
   填進 `index.html` 的 `const TEL={url:'',key:''}` 與 `admin.html` 的 `const SB={url:'',key:''}`。
   - 這把金鑰本來就是公開用的，資料庫只允許它呼叫 `report()` 寫入，讀不到任何資料。
   - **絕對不要**把 `service_role` / secret key 放進任何網頁或 GitHub。
6. 後台網址：`https://saltsearookie.github.io/TCG/admin.html`

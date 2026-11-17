-- 鹽海新鮮人：匿名遊玩統計（回訪資訊＋卡冊資訊）
-- 在 Supabase 後台「SQL Editor」貼上整份執行一次即可。可重複執行。
--
-- 安全設計重點
--   * 遊戲端（anon / publishable key）只能呼叫 public.report() 寫入，不能讀、改、刪任何資料表。
--   * report() 會檢查並裁切所有輸入（ID 格式、卡片編號、數字上限、資料大小），並限制寫入頻率。
--   * 只有列在 public.admins 裡的登入帳號能讀資料（後台 admin.html 使用）。
--   * 不存 IP、姓名、Email、裝置資訊；玩家只用遊戲隨機產生的 20 碼 ID 區分。

-- ---------- tables ----------
create table if not exists public.players (
  pid           text primary key check (pid ~ '^[a-z0-9]{20}$'),
  first_seen    timestamptz not null default now(),
  last_seen     timestamptz not null default now(),
  app_ver       text,
  login_day     int  not null default 0,   -- 目前連續簽到第幾天（1~7）
  login_last    text,                      -- 最後簽到日（玩家手機日期）
  weeks         int  not null default 0,   -- 完成 7 天簽到的次數
  salts         int  not null default 0,   -- 鹽田累計收成次數
  tasks_claimed int  not null default 0,   -- 累計領取的每日任務數
  draws         int  not null default 0,   -- 累計抽卡次數
  owned         jsonb not null default '{}'::jsonb,  -- {"卡片編號": 張數}
  ach           text[] not null default '{}'         -- 已解鎖成就 key
);

create table if not exists public.visits (
  pid           text not null references public.players(pid) on delete cascade,
  day           date not null,             -- 台灣日期
  opens         int  not null default 0,   -- 當天打開遊戲次數
  task_ids      text[] not null default '{}',
  tasks_done    int  not null default 0,   -- 當天完成的任務數（0~3）
  tasks_claimed int  not null default 0,   -- 當天已領取的任務數（0~3）
  updated_at    timestamptz not null default now(),
  primary key (pid, day)
);
create index if not exists visits_day_idx on public.visits(day);

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- ---------- lock everything down ----------
alter table public.players enable row level security;
alter table public.visits  enable row level security;
alter table public.admins  enable row level security;
revoke all on public.players, public.visits, public.admins from anon, authenticated, public;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

grant select on public.players, public.visits to authenticated;
drop policy if exists admin_read_players on public.players;
drop policy if exists admin_read_visits  on public.visits;
create policy admin_read_players on public.players for select to authenticated using (public.is_admin());
create policy admin_read_visits  on public.visits  for select to authenticated using (public.is_admin());

-- ---------- write function (the only thing the game can call) ----------
create or replace function public._ci(v text, mx int) returns int
language sql immutable as $$
  select case when v ~ '^[0-9]{1,7}$' then least(v::int, mx) else 0 end;
$$;
revoke all on function public._ci(text, int) from public, anon, authenticated;

create or replace function public.report(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_pid   text := p->>'pid';
  v_day   date := (now() at time zone 'Asia/Taipei')::date;
  v_last  timestamptz;
  v_owned jsonb;
  v_ach   text[];
  v_tids  text[];
  v_open  int := case when p->>'open' = 'true' then 1 else 0 end;
begin
  if v_pid is null or v_pid !~ '^[a-z0-9]{20}$' then return; end if;
  if pg_column_size(p) > 6000 then return; end if;

  select last_seen into v_last from players where pid = v_pid;
  -- throttle: at most one write per player every 10 seconds (a new app session always counts)
  if v_last is not null and now() - v_last < interval '10 seconds' and v_open = 0 then return; end if;
  -- flood guard: refuse brand-new IDs when too many appeared in the last hour
  if v_last is null and (select count(*) from players where first_seen > now() - interval '1 hour') >= 300 then return; end if;

  select coalesce(jsonb_object_agg(key, public._ci(value #>> '{}', 9999)), '{}'::jsonb) into v_owned
    from jsonb_each(case when jsonb_typeof(p->'owned') = 'object' then p->'owned' else '{}'::jsonb end)
   where key ~ '^([0-9]|1[0-5])$';
  select coalesce(array_agg(distinct x), '{}') into v_ach
    from (select x from jsonb_array_elements_text(case when jsonb_typeof(p->'ach') = 'array' then p->'ach' else '[]'::jsonb end) x
           where x ~ '^[a-z0-9]{1,12}$' limit 40) s;
  select coalesce(array_agg(x), '{}') into v_tids
    from (select x from jsonb_array_elements_text(case when jsonb_typeof(p->'tids') = 'array' then p->'tids' else '[]'::jsonb end) x
           where x ~ '^[a-z0-9]{1,8}$' limit 3) s;

  insert into players as t (pid, app_ver, login_day, login_last, weeks, salts, tasks_claimed, draws, owned, ach)
  values (v_pid, left(regexp_replace(coalesce(p->>'v',''), '[^0-9.]', '', 'g'), 12),
          public._ci(p->>'lday', 7), left(regexp_replace(coalesce(p->>'llast',''), '[^0-9-]', '', 'g'), 10),
          public._ci(p->>'weeks', 99999), public._ci(p->>'salts', 99999), public._ci(p->>'tasks', 99999),
          public._ci(p->>'draws', 999999), v_owned, v_ach)
  on conflict (pid) do update set
    last_seen = now(), app_ver = excluded.app_ver, login_day = excluded.login_day, login_last = excluded.login_last,
    weeks = excluded.weeks, salts = excluded.salts, tasks_claimed = excluded.tasks_claimed, draws = excluded.draws,
    owned = excluded.owned, ach = excluded.ach;

  insert into visits as v (pid, day, opens, task_ids, tasks_done, tasks_claimed)
  values (v_pid, v_day, v_open, v_tids, public._ci(p->>'tdone', 3), public._ci(p->>'tclaim', 3))
  on conflict (pid, day) do update set
    opens = v.opens + excluded.opens, task_ids = excluded.task_ids,
    tasks_done = excluded.tasks_done, tasks_claimed = excluded.tasks_claimed, updated_at = now();
end;
$$;
revoke all on function public.report(jsonb) from public;
grant execute on function public.report(jsonb) to anon, authenticated;

-- ---------- 最後一步：把你的管理員帳號加進來 ----------
-- 先到 Authentication → Users → Add user 建立帳號（勾選 Auto Confirm），再把下面的 email 換成你的並執行：
-- insert into public.admins (user_id) select id from auth.users where email = '你的email@example.com' on conflict do nothing;

-- ---------- 玩家要求刪除資料時 ----------
-- delete from public.players where pid = '玩家提供的匿名ID';   -- 回訪紀錄會一起刪除

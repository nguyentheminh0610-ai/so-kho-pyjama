-- Sổ Kho Pyjama — schema cho Supabase project chung với Sổ Vận Hành
-- Chạy toàn bộ file này trong Supabase Dashboard > SQL Editor > New query > Run
-- An toàn khi chạy lại nhiều lần (mọi lệnh đều "if not exists" / "if exists").

create table if not exists warehouse_return_checks (
  id bigint generated always as identity primary key,
  code text not null unique,                  -- mã vận đơn quét được lúc nhận hàng (GHN/J&T/SPX, hoặc mã gửi đi cũ nếu là "đổi ý giữa đường")
  oid text,                                    -- mã đơn hàng (tuỳ chọn) — bắt buộc dùng để đối chiếu khi đơn không có mã vận đơn trả riêng
  platform text not null check (platform in ('tiktok','shopee')),
  carrier text,                                -- 'J&T Express' | 'GHN' | 'Shopee Express'
  staff text,
  scan_date date not null default current_date,
  scanned_at timestamptz not null default now(),
  return_type text check (return_type in ('boom','doi_tra')),  -- 'boom' = huỷ/khách không nhận hàng (không cần bóc kiểm) | 'doi_tra' = hoàn trả, khách đã nhận rồi gửi lại (phải bóc kiểm SKU/SL khớp lệnh trả trên sàn)
  has_problem boolean not null default false,  -- chỉ áp dụng cho return_type = 'doi_tra' (Hoàn trả); đơn Huỷ/Bom hàng chỉ cần xác nhận, không có bước này
  problem_type text,                           -- hu_hong (Hàng hỏng) | sai_hang (Hàng không phải của shop)
  note text,                                   -- không còn nhập từ UI (giữ cột phòng khi cần dùng lại)
  complaint_status text not null default 'none' check (complaint_status in ('none','pending','submitted','resolved')),
  -- các trường bổ sung sau (bước rà soát), chỉ áp dụng cho return_type = 'doi_tra':
  sku text,
  quantity integer,
  return_category text,
  order_status text,                           -- vd "Nguyên vẹn"
  return_reason text,
  matched_in_platform_file boolean not null default false,  -- true khi đối chiếu khớp được với hoanVeKhoDetail (theo mã vận đơn hoặc oid)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- An toàn khi chạy lại trên bảng đã có từ trước (thêm cột mới không ảnh hưởng dữ liệu cũ):
alter table warehouse_return_checks add column if not exists return_type text check (return_type in ('boom','doi_tra'));
alter table warehouse_return_checks add column if not exists oid text;
alter table warehouse_return_checks drop column if exists cost;  -- bỏ trường chi phí, không dùng nữa

create table if not exists warehouse_outbound_checks (
  id bigint generated always as identity primary key,
  code text not null unique,
  platform text not null check (platform in ('tiktok','shopee')),
  carrier text,
  staff text,
  scan_date date not null default current_date,
  scanned_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

-- Trạng thái xử lý cho từng đơn "sàn báo hoàn nhưng kho chưa nhận", theo dõi độc lập
-- với từng lần chạy đối chiếu (vì đối chiếu giờ gộp nhiều tháng và chạy lại nhiều lần).
-- match_key = mã vận đơn trả (nếu sàn có) hoặc 'oid:<mã đơn hàng>' (nếu nhóm này không có mã vận đơn riêng,
-- vd Shopee "đổi ý giữa đường" hoặc TikTok "huỷ sau khi đã gửi hàng").
create table if not exists warehouse_return_match_status (
  id bigint generated always as identity primary key,
  platform text not null check (platform in ('tiktok','shopee')),
  match_key text not null,
  match_type text not null check (match_type in ('tracking','oid')),
  loai text,                                   -- loại như sàn trả về, vd "Đơn trả (khách gửi trả hàng)"
  status text not null default 'pending' check (status in ('pending','resolved','lost')),
  note text,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (platform, match_key)
);

create index if not exists idx_wrc_scan_date on warehouse_return_checks(scan_date);
create index if not exists idx_wrc_return_type on warehouse_return_checks(return_type);
create index if not exists idx_wrc_oid on warehouse_return_checks(oid);
create index if not exists idx_woc_scan_date on warehouse_outbound_checks(scan_date);

-- tự cập nhật updated_at
create or replace function set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_wrc_updated on warehouse_return_checks;
create trigger trg_wrc_updated before update on warehouse_return_checks
for each row execute function set_updated_at();

drop trigger if exists trg_match_status_updated on warehouse_return_match_status;
create trigger trg_match_status_updated before update on warehouse_return_match_status
for each row execute function set_updated_at();

-- Bật RLS + cho phép anon key (dùng thẳng từ trình duyệt, giống Sổ Vận Hành) đọc/ghi
-- các bảng kho riêng này. KHÔNG đụng gì tới bảng monthly_reports đang có.
alter table warehouse_return_checks enable row level security;
alter table warehouse_outbound_checks enable row level security;
alter table warehouse_return_match_status enable row level security;

drop policy if exists "anon full access" on warehouse_return_checks;
create policy "anon full access" on warehouse_return_checks for all to anon using (true) with check (true);

drop policy if exists "anon full access" on warehouse_outbound_checks;
create policy "anon full access" on warehouse_outbound_checks for all to anon using (true) with check (true);

drop policy if exists "anon full access" on warehouse_return_match_status;
create policy "anon full access" on warehouse_return_match_status for all to anon using (true) with check (true);

-- Bảng warehouse_reconciliations (bản cũ, đối chiếu bằng upload file) không dùng nữa —
-- có thể xoá thủ công nếu anh đã lỡ tạo ở lần chạy trước, không bắt buộc:
-- drop table if exists warehouse_reconciliations;

-- ================================================================================
-- TỔNG HỢP THÁNG TỰ ĐỘNG — đẩy vào 1 bảng riêng của Sổ Kho (không đụng monthly_reports),
-- để Sổ Vận Hành có thể tự đọc mà không cần anh tải file / gửi tay mỗi tháng.
-- Bảng này CHỈ được ghi bởi hàm generate_warehouse_monthly_summary() bên dưới (chạy tự
-- động qua pg_cron) — anon key chỉ có quyền ĐỌC, không ghi được, để không ai lỡ tay sửa.
-- Chỉ đẩy lên CON SỐ TỔNG (không kèm mã vận đơn / sàn nào cụ thể của từng đơn) — gọn cho
-- bên Sổ Vận Hành, không cần chi tiết. Muốn xem đầy đủ từng đơn thì dùng nút "Xuất Excel"
-- ở mục Danh sách ngay trong Sổ Kho.
--
-- LƯU Ý (tạm chưa đẩy số "đối chiếu bị lệch"): việc so khớp mã vận đơn/mã đơn hàng giữa dữ
-- liệu kho và file sàn xuất chưa đủ tin cậy, vì lúc tích đơn hoàn có khi tích mã vận đơn (mã
-- đơn vị vận chuyển) có khi lại là mã đơn hàng của sàn tuỳ đơn, trong khi file sàn xuất ra
-- mỗi đơn có thể chỉ có 1 trong 2 mã đó — so sai cột dễ ra kết quả lệch giả. Cần xử lý kỹ hơn
-- (chuẩn hoá rõ loại mã đang lưu, hoặc nhận diện được sàn xuất mã gì) trước khi tự động đẩy số
-- này lên; mục Tổng quan trong Sổ Kho vẫn còn cách xử lý ổn hơn (chốt tay từng đơn tồn đọng).
-- ================================================================================
create table if not exists warehouse_monthly_summary (
  id bigint generated always as identity primary key,
  label text not null,                              -- vd "09/2026"
  period_start date not null,
  period_end date not null,
  generated_at timestamptz not null default now(),
  total_returns integer not null default 0,          -- tổng đơn hoàn kho đã nhận trong tháng (Hoàn trả + Huỷ/Bom hàng)
  total_returns_problem integer not null default 0,  -- trong đó, số đơn có vấn đề (hàng hỏng / sai hàng)
  total_outbound integer not null default 0,         -- tổng đơn tích đi (gửi hàng) trong tháng
  unique (period_start, period_end)
);

-- An toàn khi chạy lại trên bảng đã có từ trước (thêm cột mới không ảnh hưởng dữ liệu cũ; nếu
-- anh đã lỡ chạy bản có tính "đối chiếu bị lệch" trước đó, script này tự dọn 2 cột đó luôn):
alter table warehouse_monthly_summary add column if not exists total_returns integer not null default 0;
alter table warehouse_monthly_summary add column if not exists total_returns_problem integer not null default 0;
alter table warehouse_monthly_summary add column if not exists total_outbound integer not null default 0;
alter table warehouse_monthly_summary drop column if exists data;
alter table warehouse_monthly_summary drop column if exists outbound_total;
alter table warehouse_monthly_summary drop column if exists outbound_data;
alter table warehouse_monthly_summary drop column if exists mismatch_thieu;
alter table warehouse_monthly_summary drop column if exists mismatch_thua;

alter table warehouse_monthly_summary enable row level security;
drop policy if exists "anon read access" on warehouse_monthly_summary;
create policy "anon read access" on warehouse_monthly_summary for select to anon using (true);
-- Cố ý KHÔNG tạo policy insert/update/delete cho anon — chỉ hàm dưới đây (chạy bằng
-- quyền chủ sở hữu qua pg_cron) mới ghi được vào bảng này.

-- target_month: truyền bất kỳ ngày nào trong tháng muốn tổng hợp (mặc định = tháng trước,
-- đúng lúc pg_cron chạy vào đầu tháng sau). Chạy tay `select generate_warehouse_monthly_summary('2026-08-01');`
-- nếu muốn tổng hợp bù cho 1 tháng cụ thể trước khi lịch tự động bắt đầu.
create or replace function generate_warehouse_monthly_summary(
  target_month date default (date_trunc('month', current_date) - interval '1 month')::date
) returns void language plpgsql as $$
declare
  v_start date := date_trunc('month', target_month)::date;
  v_end date := (date_trunc('month', target_month) + interval '1 month' - interval '1 day')::date;
  v_label text := to_char(v_start, 'MM/YYYY');
  v_total_returns integer;
  v_total_returns_problem integer;
  v_total_outbound integer;
begin
  select count(*), count(*) filter (where has_problem)
  into v_total_returns, v_total_returns_problem
  from warehouse_return_checks
  where scan_date >= v_start and scan_date <= v_end;

  select count(*)
  into v_total_outbound
  from warehouse_outbound_checks
  where scan_date >= v_start and scan_date <= v_end;

  insert into warehouse_monthly_summary
    (label, period_start, period_end, total_returns, total_returns_problem, total_outbound, generated_at)
  values
    (v_label, v_start, v_end, v_total_returns, v_total_returns_problem, v_total_outbound, now())
  on conflict (period_start, period_end)
  do update set
    total_returns = excluded.total_returns,
    total_returns_problem = excluded.total_returns_problem,
    total_outbound = excluded.total_outbound,
    generated_at = excluded.generated_at,
    label = excluded.label;
end;
$$;

-- BƯỚC CUỐI — chỉ cần làm 1 lần, ngay trong Supabase Dashboard > SQL Editor:
-- 1) Bật extension pg_cron: Database > Extensions > tìm "pg_cron" > Enable
--    (hoặc chạy: create extension if not exists pg_cron;)
-- 2) Đặt lịch tự động chạy vào 02:00 sáng giờ Việt Nam, ngày mồng 2 hàng tháng — tổng hợp
--    dữ liệu của tháng vừa kết thúc (chờ thêm 1 ngày so với bản trước để trừ hao đơn về muộn
--    cuối tháng chưa kịp tích). Lưu ý: pg_cron chạy theo giờ UTC (UTC = giờ VN - 7 giờ),
--    nên 02:00 sáng ngày mồng 2 giờ VN = 19:00 tối ngày mồng 1 giờ UTC:
--      select cron.schedule(
--        'warehouse-monthly-summary',
--        '0 19 1 * *',
--        $$select generate_warehouse_monthly_summary();$$
--      );
--    Nếu trước đó anh đã lỡ chạy lịch cũ rồi, chạy thêm lệnh này trước để xoá lịch cũ:
--      select cron.unschedule('warehouse-monthly-summary');
-- 3) (Tuỳ chọn) Tổng hợp bù ngay cho tháng hiện tại/tháng trước để có dữ liệu thử luôn,
--    không cần đợi tới đầu tháng sau:
--      select generate_warehouse_monthly_summary();               -- tháng trước
--      select generate_warehouse_monthly_summary('2026-09-01');   -- 1 tháng cụ thể
-- Từ đây Sổ Vận Hành chỉ cần đọc bảng warehouse_monthly_summary (cùng Supabase project,
-- cùng anon key) bằng 1 câu query, không cần Sổ Kho gửi file hay thao tác gì thêm mỗi tháng.

-- QUAN TRỌNG — KHÔNG chạy đoạn dưới đây tự động:
-- Web Sổ Kho cần đọc (chỉ đọc) cột `data` của bảng monthly_reports để lấy mảng
-- data.hoanVeKhoDetail dùng cho đối chiếu. Nếu bảng monthly_reports hiện KHÔNG bật RLS
-- (nghĩa là anon key đang đọc/ghi tự do — rất có thể đúng vậy vì Sổ Vận Hành đang chạy
-- ổn với đúng cách này) thì KHÔNG cần làm gì thêm, anon key đã đọc được sẵn.
-- Chỉ nếu monthly_reports ĐÃ bật RLS (kiểm tra ở Supabase Dashboard > Authentication > Policies)
-- và web Sổ Kho báo lỗi không đọc được, thì mới cần thêm 1 policy SELECT cho anon:
--   create policy "anon read access" on monthly_reports for select to anon using (true);
-- Tuyệt đối không bật RLS mới trên bảng này nếu nó đang tắt — bật lên mà thiếu policy ghi
-- sẽ làm gãy luôn app Sổ Vận Hành đang chạy (mất quyền insert/update của anon).

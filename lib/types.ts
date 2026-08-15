export type ProductionRole = "master" | "tester" | "repair" | "quality_control" | "packing";

export type ProductStatus = "assembly" | "testing" | "repair" | "quality_control" | "rework" | "packing" | "packed";

export type ProductEventType =
  | "sent_to_testing"
  | "sent_to_repair"
  | "repair_started"
  | "repair_completed"
  | "sent_to_quality_control"
  | "sent_to_rework"
  | "rework_started"
  | "rework_completed"
  | "sent_to_packing"
  | "packed"
  | "deleted";

export type UserProfile = {
  id: string;
  phone_e164: string | null;
  username: string;
  display_name: string;
  personal_number: string | null;
  shift_number: 1 | 2 | 5 | null;
  job_title: string | null;
  workplace: "ПЦ Рябиновая" | "ПЦ Алтуфьево-1" | "ПЦ Алтуфьево-2" | null;
  production_role: ProductionRole | null;
  production_line_id: string | null;
  shift_id: string | null;
  tester_cube_number: number | null;
  production_admin: boolean;
  avatar_url: string | null;
  bio: string | null;
  status: string;
  last_seen: string | null;
  created_at: string;
  updated_at: string;
};

export type ProductionLine = {
  id: string;
  number: number;
  name: string;
  is_active: boolean;
  created_at: string;
};

export type ProductionShift = {
  id: string;
  code: "1" | "2" | "5/2";
  name: string;
  is_active: boolean;
  created_at: string;
};

export type Product = {
  id: string;
  full_qr: string;
  release: string;
  serial_number: string;
  current_status: ProductStatus;
  current_line_id: string | null;
  current_shift_id: string | null;
  deleted_at: string | null;
  deleted_by: string | null;
  deletion_reason: string | null;
  created_at: string;
  updated_at: string;
};

export type ProductEvent = {
  id: string;
  product_id: string;
  event_type: ProductEventType;
  from_status: ProductStatus | null;
  to_status: ProductStatus | null;
  line_id: string | null;
  shift_id: string | null;
  user_id: string;
  reason_text: string | null;
  workstation_name: string | null;
  created_at: string;
};

export type ProductionQueueItem = {
  id: string;
  full_qr: string;
  release: string;
  serial_number: string;
  current_status: ProductStatus;
  line_number: number | null;
  shift_name: string | null;
  reason_text: string | null;
  sent_by: string | null;
  event_type: ProductEventType | null;
  event_time: string | null;
};

export type ProductionProductListItem = {
  id: string;
  full_qr: string;
  release: string;
  serial_number: string;
  current_status: ProductStatus;
  line_number: number | null;
  shift_name: string | null;
  last_event_type: ProductEventType | null;
  last_event_at: string | null;
  created_at: string;
  updated_at: string;
};

export type WorkpieceDefectListItem = {
  id: string;
  qr_code: string;
  reason_text: string;
  line_number: number;
  shift_name: string;
  reported_by: string;
  reporter_name: string;
  created_at: string;
  updated_at: string;
};

export type ProductHistoryEvent = {
  id: string;
  event_type: ProductEventType;
  from_status: ProductStatus | null;
  to_status: ProductStatus | null;
  reason_text: string | null;
  created_at: string;
  user_id: string;
  user_name: string | null;
  line_number: number | null;
  shift_name: string | null;
  workstation_name: string | null;
};

export type ProductDetails = {
  product: Omit<Product, "current_line_id" | "current_shift_id" | "deleted_at" | "deleted_by" | "deletion_reason"> & { line_number: number | null; shift_name: string | null };
  events: ProductHistoryEvent[];
};

export type Message = {
  id: number;
  chat_id: string;
  sender_id: string;
  body: string | null;
  attachment_path: string | null;
  attachment_name: string | null;
  attachment_type: string | null;
  attachment_size: number | null;
  task_id: number | null;
  task_event: "assignment" | "read" | null;
  created_at: string;
};

export type CalendarTask = {
  id: number;
  owner_id: string;
  contact_id: string;
  title: string;
  notes: string;
  starts_at: string;
  ends_at: string | null;
  status: "planned" | "done";
  completed_by: string | null;
  completed_at: string | null;
  created_at: string;
  updated_at: string;
};

export type TaskAlert = CalendarTask & {
  owner_name: string;
  owner_avatar_url: string | null;
};

export type GroupChat = {
  id: string;
  type: "group";
  title: string;
  avatar_url: string | null;
  created_by: string | null;
  created_at: string;
  members: UserProfile[];
};

export type CallRecord = {
  id: string;
  caller_id: string;
  callee_id: string;
  status: "ringing" | "accepted" | "declined" | "ended" | "missed";
  offer: RTCSessionDescriptionInit;
  answer: RTCSessionDescriptionInit | null;
  created_at: string;
  accepted_at: string | null;
  ended_at: string | null;
  updated_at: string;
};

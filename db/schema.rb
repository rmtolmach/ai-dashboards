# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_10_06_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "backend_monthly_reviews", force: :cascade do |t|
    t.date "month", null: false
    t.string "repository_name", null: false
    t.string "repository_owner", null: false
    t.integer "total_approvals", default: 0
    t.jsonb "pr_data", default: []
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["repository_owner", "month"], name: "index_backend_monthly_reviews_on_repository_owner_and_month"
    t.index ["repository_owner", "repository_name", "month"], name: "index_backend_monthly_reviews_unique", unique: true
  end

  create_table "backend_review_group_members", force: :cascade do |t|
    t.string "username"
    t.string "avatar_url"
    t.datetime "fetched_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["username"], name: "index_backend_review_group_members_on_username"
  end

  create_table "check_runs", force: :cascade do |t|
    t.bigint "pull_request_id", null: false
    t.string "name"
    t.string "status"
    t.string "url"
    t.text "description"
    t.boolean "required"
    t.string "suite_name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["pull_request_id", "suite_name"], name: "index_check_runs_on_pull_request_id_and_suite_name"
    t.index ["pull_request_id"], name: "index_check_runs_on_pull_request_id"
    t.index ["required"], name: "index_check_runs_on_required"
    t.index ["status"], name: "index_check_runs_on_status"
  end

  create_table "cron_job_logs", force: :cascade do |t|
    t.string "status"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.string "error_class"
    t.text "error_message"
    t.text "error_backtrace"
    t.integer "prs_processed"
    t.integer "prs_updated"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "daily_snapshots", force: :cascade do |t|
    t.date "snapshot_date", null: false
    t.integer "total_prs", default: 0
    t.integer "approved_prs", default: 0
    t.integer "prs_with_changes_requested", default: 0
    t.integer "pending_review_prs", default: 0
    t.integer "draft_prs", default: 0
    t.integer "failing_ci_prs", default: 0
    t.integer "successful_ci_prs", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "prs_opened_today", default: 0
    t.integer "prs_closed_today", default: 0
    t.integer "prs_merged_today", default: 0
    t.integer "prs_approved_during_business_hours", default: 0
    t.datetime "business_hours_start"
    t.datetime "business_hours_end"
    t.string "repository_name"
    t.string "repository_owner"
    t.index ["repository_name"], name: "index_daily_snapshots_on_repository_name"
    t.index ["repository_owner", "repository_name"], name: "index_daily_snapshots_on_repository_owner_and_repository_name"
    t.index ["snapshot_date", "repository_owner", "repository_name"], name: "index_daily_snapshots_on_date_and_repository", unique: true
  end

  create_table "login_events", force: :cascade do |t|
    t.string "email", null: false
    t.string "name"
    t.string "picture"
    t.datetime "logged_in_at", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email", "logged_in_at"], name: "index_login_events_on_email_and_logged_in_at"
    t.index ["email"], name: "index_login_events_on_email"
    t.index ["logged_in_at"], name: "index_login_events_on_logged_in_at"
  end

  create_table "pull_request_comments", force: :cascade do |t|
    t.bigint "pull_request_id", null: false
    t.bigint "github_id", null: false
    t.string "user", null: false
    t.text "body"
    t.datetime "commented_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["github_id"], name: "index_pull_request_comments_on_github_id", unique: true
    t.index ["pull_request_id", "commented_at"], name: "idx_on_pull_request_id_commented_at_9baa8e17dc"
    t.index ["pull_request_id"], name: "index_pull_request_comments_on_pull_request_id"
  end

  create_table "pull_request_review_comments", force: :cascade do |t|
    t.bigint "pull_request_id", null: false
    t.bigint "github_id", null: false
    t.bigint "pull_request_review_id"
    t.string "user", null: false
    t.text "body"
    t.string "path"
    t.integer "line"
    t.datetime "commented_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["github_id"], name: "index_pull_request_review_comments_on_github_id", unique: true
    t.index ["pull_request_id", "commented_at"], name: "idx_on_pull_request_id_commented_at_4311c003c2"
    t.index ["pull_request_id"], name: "index_pull_request_review_comments_on_pull_request_id"
  end

  create_table "pull_request_reviews", force: :cascade do |t|
    t.bigint "pull_request_id", null: false
    t.bigint "github_id"
    t.string "user"
    t.string "state"
    t.text "body"
    t.datetime "submitted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["github_id"], name: "index_pull_request_reviews_on_github_id", unique: true
    t.index ["pull_request_id"], name: "index_pull_request_reviews_on_pull_request_id"
    t.index ["state"], name: "index_pull_request_reviews_on_state"
  end

  create_table "pull_requests", force: :cascade do |t|
    t.bigint "github_id"
    t.integer "number"
    t.string "title"
    t.string "author"
    t.string "state"
    t.boolean "draft"
    t.string "url"
    t.datetime "pr_created_at"
    t.datetime "pr_updated_at"
    t.string "ci_status"
    t.integer "total_checks"
    t.integer "successful_checks"
    t.integer "failed_checks"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "backend_approval_status", default: "not_approved"
    t.boolean "ready_for_backend_review", default: false
    t.datetime "approved_at"
    t.string "head_sha"
    t.datetime "last_scraped_at"
    t.integer "pending_checks", default: 0
    t.string "repository_name"
    t.string "repository_owner"
    t.jsonb "labels", default: []
    t.datetime "ready_for_backend_review_at"
    t.boolean "awaiting_author_changes", default: false
    t.datetime "backend_approved_at"
    t.jsonb "pending_reviewers", default: []
    t.jsonb "pending_teams", default: []
    t.integer "additions"
    t.integer "deletions"
    t.integer "changed_files"
    t.index ["awaiting_author_changes"], name: "index_pull_requests_on_awaiting_author_changes"
    t.index ["backend_approval_status"], name: "index_pull_requests_on_backend_approval_status"
    t.index ["github_id"], name: "index_pull_requests_on_github_id", unique: true
    t.index ["head_sha"], name: "index_pull_requests_on_head_sha"
    t.index ["labels"], name: "index_pull_requests_on_labels", using: :gin
    t.index ["ready_for_backend_review_at"], name: "index_pull_requests_on_ready_for_backend_review_at"
    t.index ["repository_name"], name: "index_pull_requests_on_repository_name"
    t.index ["repository_owner", "repository_name"], name: "index_pull_requests_on_repository_owner_and_repository_name"
  end

  create_table "review_events", force: :cascade do |t|
    t.bigint "github_id", null: false
    t.string "reviewer", null: false
    t.string "state", null: false
    t.datetime "submitted_at", null: false
    t.integer "pr_number"
    t.string "repository_name"
    t.string "repository_owner"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "pr_author"
    t.index ["github_id"], name: "index_review_events_on_github_id", unique: true
    t.index ["reviewer", "submitted_at"], name: "index_review_events_on_reviewer_and_submitted_at"
    t.index ["submitted_at"], name: "index_review_events_on_submitted_at"
  end

  create_table "support_rotations", force: :cascade do |t|
    t.integer "sprint_number"
    t.string "engineer_name"
    t.date "start_date"
    t.date "end_date"
    t.string "repository_name"
    t.string "repository_owner"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["repository_name", "repository_owner"], name: "idx_on_repository_name_repository_owner_dfe8d3e20e"
    t.index ["sprint_number"], name: "index_support_rotations_on_sprint_number"
    t.index ["start_date", "end_date"], name: "index_support_rotations_on_start_date_and_end_date"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "github_id"
    t.string "github_username"
    t.string "email"
    t.string "name"
    t.string "avatar_url"
    t.boolean "is_va_member", default: false, null: false
    t.datetime "last_login_at"
    t.text "access_token_encrypted"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["github_id"], name: "index_users_on_github_id", unique: true
    t.index ["github_username"], name: "index_users_on_github_username", unique: true
  end

  create_table "webhook_events", force: :cascade do |t|
    t.string "event_type"
    t.string "github_delivery_id"
    t.text "payload"
    t.string "status"
    t.text "error_message"
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "check_runs", "pull_requests"
  add_foreign_key "pull_request_comments", "pull_requests"
  add_foreign_key "pull_request_reviews", "pull_requests"
end

# Builds the JSON-serializable payload for the /api/v1/reviews endpoint.
#
# Extracted from ReviewsController so that scraper jobs can pre-build the
# payload after each scrape and cache the result. With the pre-built JSON
# cached, the reviews endpoint becomes a fast cache lookup instead of a
# 1-2 second ActiveRecord traversal of every open PR's reviews/comments.
#
# Usage:
#   payload = BuildReviewsPayloadService.call(
#     repository_name: nil,        # nil = all repos
#     repository_owner: nil,
#   )
#   Rails.cache.write("prebuilt_reviews:all", payload, expires_in: 24.hours)
class BuildReviewsPayloadService
  def self.call(repository_name: nil, repository_owner: nil)
    new(repository_name: repository_name, repository_owner: repository_owner).call
  end

  def initialize(repository_name: nil, repository_owner: nil)
    @repository_name = repository_name
    @repository_owner = repository_owner
  end

  def call
    has_repository_columns = PullRequest.column_names.include?("repository_name")

    base_scope = if @repository_name && @repository_owner && has_repository_columns
      PullRequest.where(repository_name: @repository_name, repository_owner: @repository_owner)
    elsif has_repository_columns
      PullRequest.all
    else
      PullRequest
    end

    open_pull_requests = base_scope.open
      .where(backend_approval_status: "not_approved")
      .includes(:pull_request_reviews, :pull_request_comments, :pull_request_review_comments)
      .order(pr_updated_at: :desc)
      .limit(150)

    approved_pull_requests = base_scope.open
      .where(backend_approval_status: "approved")
      .includes(:pull_request_reviews, :pull_request_comments, :pull_request_review_comments)
      .order(pr_updated_at: :desc)
      .limit(100)

    if open_pull_requests.empty? && approved_pull_requests.empty?
      return {
        pull_requests: [],
        approved_pull_requests: [],
        count: 0,
        approved_count: 0,
        repository: repository_label,
        message: @repository_name == "vets-api" ?
          "Data is being refreshed. Please check back in a few minutes." :
          "Loading data for #{@repository_name}. This may take a few minutes for the first load.",
        last_updated: nil,
        updating: true
      }
    end

    BackendReviewGroupMember.cache_members!

    all_pr_ids = (open_pull_requests.map(&:id) + approved_pull_requests.map(&:id)).uniq
    failing_checks_by_pr = CheckRun
      .where(pull_request_id: all_pr_ids)
      .where(status: [ "failure", "error", "cancelled" ])
      .select(:pull_request_id, :suite_name, :name, :status, :url, :description, :required)
      .group_by(&:pull_request_id)

    open_pr_data = open_pull_requests.map { |pr| format_pr(pr, failing_checks_by_pr) }
    approved_pr_data = approved_pull_requests.map { |pr| format_pr(pr, failing_checks_by_pr) }

    recent_pr_update = if @repository_name && @repository_owner
      PullRequest
        .where(repository_owner: @repository_owner, repository_name: @repository_name)
        .maximum(:updated_at)
    else
      PullRequest.maximum(:updated_at)
    end

    {
      pull_requests: open_pr_data,
      approved_pull_requests: approved_pr_data,
      count: open_pr_data.length,
      approved_count: approved_pr_data.length,
      repository: repository_label,
      last_updated: recent_pr_update || Time.current
    }
  end

  private

  def repository_label
    @repository_name && @repository_owner ? "#{@repository_owner}/#{@repository_name}" : "All repositories"
  end

  def format_pr(pr, failing_checks_by_pr)
    pr_failing_checks = failing_checks_by_pr[pr.id] || []
    failing_checks = pr_failing_checks.map do |check|
      {
        name: check.suite_name || check.name,
        status: check.status,
        url: check.url,
        description: check.description,
        required: check.required
      }
    end.uniq { |c| c[:name] }

    {
      id: pr.github_id,
      number: pr.number,
      title: pr.title,
      author: pr.author,
      created_at: pr.pr_created_at,
      updated_at: pr.pr_updated_at,
      url: pr.url,
      state: pr.state,
      draft: pr.draft,
      mergeable: nil,
      additions: pr.additions,
      deletions: pr.deletions,
      changed_files: pr.changed_files,
      ci_status: pr.ci_status || "pending",
      failing_checks: failing_checks,
      total_checks: pr.total_checks,
      successful_checks: pr.successful_checks,
      failed_checks: pr.failed_checks,
      pending_checks: pr.pending_checks,
      backend_approval_status: pr.backend_approval_status,
      approval_summary: pr.approval_summary,
      ready_for_backend_review: pr.ready_for_backend_review,
      awaiting_author_changes: pr.respond_to?(:awaiting_author_changes) ? pr.awaiting_author_changes : false,
      labels: pr.labels || [],
      pending_reviewers: pr.pending_reviewers || [],
      pending_teams: pr.pending_teams || [],
      repository_name: pr.repository_name,
      repository_owner: pr.repository_owner,
      changes_requested_info: pr.changes_requested_info,
      latest_reviewer_activity: pr.respond_to?(:latest_reviewer_activity) ? pr.latest_reviewer_activity : nil
    }
  end
end

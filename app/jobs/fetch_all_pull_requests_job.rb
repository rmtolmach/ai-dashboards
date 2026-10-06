class FetchAllPullRequestsJob < ApplicationJob
  queue_as :default

  def perform(repository_name: nil, repository_owner: nil, deep_verification: false, lite_mode: false)
    Rails.logger.info "[FetchAllPullRequestsJob] Starting full PR update for #{repository_owner}/#{repository_name || 'default'} (deep_verification: #{deep_verification}, lite_mode: #{lite_mode})"

    github_service = GithubService.new(owner: repository_owner, repo: repository_name)

    # Check rate limit
    rate_limit = github_service.rate_limit
    if rate_limit.remaining < 100
      Rails.logger.warn "[FetchAllPullRequestsJob] Low API rate limit (#{rate_limit.remaining}), skipping"
      return
    end

    # Fetch all open PRs
    open_prs = github_service.all_pull_requests(state: "open")
    Rails.logger.info "[FetchAllPullRequestsJob] Found #{open_prs.count} open PRs"

    # Include every open PR regardless of base branch.
    #
    # This used to keep only PRs targeting "master", which silently hid stacked
    # PRs — ones opened against another feature branch rather than the trunk.
    # They never reached the DB at all, so no dashboard bucket could show them
    # and there was no indication anything had been dropped (e.g. #29928, which
    # needed backend review but targeted a teammate's branch).
    #
    # Downstream handling is base-branch agnostic, and the volume is small
    # (~5 of ~150 open vets-api PRs), so there's nothing to filter for here.
    master_prs = open_prs
    Rails.logger.info "[FetchAllPullRequestsJob] Processing #{master_prs.count} open PRs (all base branches)"

    # Bulk-fetch diff stats (additions/deletions/changed_files) for every open
    # PR in a couple of GraphQL calls, keyed by PR number. Cheaper than a
    # REST call per PR (see GithubService#pull_request_diff_stats).
    diff_stats_by_number = github_service.pull_request_diff_stats

    # Drop the second reference; master_prs is the same array now that nothing
    # is filtered out, so this frees no memory on its own — the GC pass below
    # is still worth keeping before the per-PR work begins.
    open_prs = nil
    GC.start

    # LITE MODE: Skip heavy operations (CI checks, reviews) for 512MB memory limit
    # Only update basic PR info and state changes
    if lite_mode
      Rails.logger.info "[FetchAllPullRequestsJob] Running in LITE MODE - skipping CI checks and reviews"
      process_prs_lite(master_prs, repository_name, repository_owner, github_service, diff_stats_by_number)
    else
      # Create services once and reuse to avoid memory allocation per PR
      shared_github_service = GithubService.new(owner: repository_owner, repo: repository_name)
      shared_hybrid_service = HybridPrCheckerService.new(owner: repository_owner, repo: repository_name)

      # Process PRs in smaller batches to avoid memory spikes (reduced to 2 for 512MB limit)
      master_prs.each_slice(2) do |batch|
        batch.each do |pr_data|
          # Find by github_id to avoid duplicate key violations
          pr = PullRequest.find_or_initialize_by(github_id: pr_data.id)

          # Check if PR was updated since last scrape
          # - head_sha change = new commits (need to refetch checks)
          # - pr_updated_at change = any update including reviews (need to refetch reviews)
          # - not backend approved = always refetch reviews to catch approval changes
          pr_has_new_commits = pr.new_record? || pr.head_sha != pr_data.head.sha
          pr_was_updated = pr.new_record? || pr.pr_updated_at != pr_data.updated_at
          needs_backend_review = pr.backend_approval_status != "approved"
          pr_changed = pr_has_new_commits || pr_was_updated || needs_backend_review

          # Set repository info if it's a new record
          if pr.new_record?
            pr.repository_name = repository_name || ENV["GITHUB_REPO"]
            pr.repository_owner = repository_owner || ENV["GITHUB_OWNER"]
          end

          diff_stats = diff_stats_by_number[pr_data.number] || {}

          pr.update!(
            github_id: pr_data.id,
            number: pr_data.number,
            title: pr_data.title,
            author: pr_data.user.login,
            state: pr_data.state,
            url: pr_data.html_url,
            pr_created_at: pr_data.created_at,
            pr_updated_at: pr_data.updated_at,
            draft: pr_data.draft || false,
            repository_name: repository_name || ENV["GITHUB_REPO"],
            repository_owner: repository_owner || ENV["GITHUB_OWNER"],
            labels: pr_data.labels.map(&:name),
            head_sha: pr_data.head.sha,
            # Pending review requests ride along on the PR list payload, so
            # capturing them costs no extra API calls. A pending codeowner team
            # means the PR is still blocked on review even when it already has
            # approvals and green CI.
            pending_reviewers: (pr_data.requested_reviewers || []).map(&:login),
            pending_teams: (pr_data.requested_teams || []).map(&:slug),
            additions: diff_stats[:additions],
            deletions: diff_stats[:deletions],
            changed_files: diff_stats[:changed_files]
          )

          # Only fetch checks if PR changed (new commits) - saves memory & API calls
          # This is the most memory-intensive operation
          if pr_changed
            fetch_pr_checks_inline(pr, shared_github_service, shared_hybrid_service)
          end
        end

        # Force garbage collection after each batch to free memory
        GC.start(full_mark: false, immediate_sweep: true)
      end
    end

    # CRITICAL: Update merged/closed PRs on EVERY run (not just deep verification)
    # This ensures merged PRs are removed from the board within 30 minutes instead of 24 hours
    Rails.logger.info "[FetchAllPullRequestsJob] Checking for merged/closed PRs"
    scope = PullRequest.where(state: "open")
    scope = scope.where(repository_name: repository_name || ENV["GITHUB_REPO"])
    scope = scope.where(repository_owner: repository_owner || ENV["GITHUB_OWNER"])

    # Find PRs that are marked "open" in DB but not in GitHub's open list
    stale_pr_numbers = scope.where.not(number: master_prs.map(&:number)).pluck(:number)

    if stale_pr_numbers.any?
      Rails.logger.info "[FetchAllPullRequestsJob] Found #{stale_pr_numbers.count} potentially merged/closed PRs: #{stale_pr_numbers.inspect}"

      stale_pr_numbers.each do |pr_number|
        begin
          actual_pr = github_service.pull_request(pr_number)
          pr_record = scope.find_by(number: pr_number)
          if pr_record
            new_state = actual_pr.merged ? "merged" : "closed"
            Rails.logger.info "[FetchAllPullRequestsJob] Updating PR ##{pr_number} from 'open' to '#{new_state}'"
            pr_record.update!(state: new_state)
          end
        rescue Octokit::NotFound
          pr_record = scope.find_by(number: pr_number)
          pr_record&.destroy
          Rails.logger.info "[FetchAllPullRequestsJob] Deleted PR ##{pr_number} (not found on GitHub)"
        rescue => e
          Rails.logger.error "[FetchAllPullRequestsJob] Error updating PR ##{pr_number}: #{e.message}"
        end

        # Small delay to avoid rate limiting
        sleep 0.2
      end
    end

    # SKIP deep verification entirely during regular runs to minimize memory usage
    # Deep verification (HTML scraping, review re-verification) is VERY memory-intensive
    # Only run once per day at 1 AM when traffic is low
    if deep_verification
      Rails.logger.info "[FetchAllPullRequestsJob] Running deep verification (review verification, HTML scraping)"

      # Verify PRs in "PRs Needing Team Review" for API lag issues
      # Process in smaller batches (5 -> 3) to reduce memory
      verify_prs_needing_review(github_service, repository_name, repository_owner)

      # Web scraping verification as final check
      # SKIP THIS - most memory-intensive operation
      # verify_prs_via_html_scraping(repository_name, repository_owner)
      Rails.logger.info "[FetchAllPullRequestsJob] Skipping HTML scraping to minimize memory usage"
    else
      Rails.logger.info "[FetchAllPullRequestsJob] Skipping deep verification to minimize memory usage"
    end

    # Update the scrape timestamp - this invalidates the reviews cache
    # The reviews controller uses this timestamp in its cache key
    scrape_key = "last_scrape:#{repository_owner}:#{repository_name}"
    Rails.cache.write(scrape_key, Time.current.to_i, expires_in: 24.hours)
    Rails.logger.info "[FetchAllPullRequestsJob] Updated scrape timestamp: #{scrape_key}"

    # Pre-build the /api/v1/reviews JSON payload so the controller can return
    # it instantly on the next request instead of doing a 1-2s DB traversal.
    RefreshReviewsCacheService.call

    Rails.logger.info "[FetchAllPullRequestsJob] Completed full PR update"

  rescue => e
    Rails.logger.error "[FetchAllPullRequestsJob] Error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end

  private

  # LITE MODE: Minimal memory footprint for 512MB Render limit
  # Only updates basic PR info, state changes, and merged/closed detection
  # Skips: CI checks, reviews fetching, approval status recalculation
  def process_prs_lite(master_prs, repository_name, repository_owner, github_service, diff_stats_by_number)
    processed = 0
    master_prs.each_slice(5) do |batch|
      batch.each do |pr_data|
        pr = PullRequest.find_or_initialize_by(github_id: pr_data.id)
        diff_stats = diff_stats_by_number[pr_data.number] || {}

        # New commits invalidate every stored check: they belong to the previous
        # head. Lite mode doesn't refetch checks, and Step 3 only reaches roughly
        # half the open PRs per run (it sleeps 30s every 10 PRs), so without this
        # a PR can display failures from a commit that is no longer its head for
        # hours — showing red for since-fixed tests, or green for newly broken
        # ones. Clearing them here is a local DELETE with no API cost; the row
        # then reads as "checks pending" until the next real fetch populates it.
        head_changed = pr.persisted? && pr.head_sha.present? && pr.head_sha != pr_data.head.sha

        if pr.new_record?
          pr.repository_name = repository_name || ENV["GITHUB_REPO"]
          pr.repository_owner = repository_owner || ENV["GITHUB_OWNER"]
        end

        pr.update!(
          github_id: pr_data.id,
          number: pr_data.number,
          title: pr_data.title,
          author: pr_data.user.login,
          state: pr_data.state,
          url: pr_data.html_url,
          pr_created_at: pr_data.created_at,
          pr_updated_at: pr_data.updated_at,
          draft: pr_data.draft || false,
          repository_name: repository_name || ENV["GITHUB_REPO"],
          repository_owner: repository_owner || ENV["GITHUB_OWNER"],
          labels: pr_data.labels.map(&:name),
          head_sha: pr_data.head.sha,
          # See note above: free on the list payload, and required to tell a
          # merge-ready PR from one still awaiting a codeowner review.
          pending_reviewers: (pr_data.requested_reviewers || []).map(&:login),
          pending_teams: (pr_data.requested_teams || []).map(&:slug),
          additions: diff_stats[:additions],
          deletions: diff_stats[:deletions],
          changed_files: diff_stats[:changed_files]
        )

        if head_changed
          pr.check_runs.destroy_all
          Rails.cache.delete("pr_#{pr.id}_failing_checks")
          pr.update!(ci_status: "pending", total_checks: 0, successful_checks: 0, failed_checks: 0)
          Rails.logger.info "[FetchAllPullRequestsJob] PR ##{pr.number}: new head, cleared stale checks"
        end

        processed += 1
      end
      GC.start(full_mark: false, immediate_sweep: true)
    end

    Rails.logger.info "[FetchAllPullRequestsJob] LITE MODE: Updated #{processed} PRs (basic info only)"

    # Still detect merged/closed PRs (low memory operation)
    detect_merged_closed_prs(master_prs, repository_name, repository_owner, github_service)
  end

  def detect_merged_closed_prs(master_prs, repository_name, repository_owner, github_service)
    scope = PullRequest.where(state: "open")
    scope = scope.where(repository_name: repository_name || ENV["GITHUB_REPO"])
    scope = scope.where(repository_owner: repository_owner || ENV["GITHUB_OWNER"])

    stale_pr_numbers = scope.where.not(number: master_prs.map(&:number)).pluck(:number)

    if stale_pr_numbers.any?
      Rails.logger.info "[FetchAllPullRequestsJob] Found #{stale_pr_numbers.count} potentially merged/closed PRs"

      stale_pr_numbers.each do |pr_number|
        begin
          actual_pr = github_service.pull_request(pr_number)
          pr_record = scope.find_by(number: pr_number)
          if pr_record
            new_state = actual_pr.merged ? "merged" : "closed"
            Rails.logger.info "[FetchAllPullRequestsJob] Updating PR ##{pr_number} to '#{new_state}'"
            pr_record.update!(state: new_state)
          end
        rescue Octokit::NotFound
          pr_record = scope.find_by(number: pr_number)
          pr_record&.destroy
        rescue => e
          Rails.logger.error "[FetchAllPullRequestsJob] Error updating PR ##{pr_number}: #{e.message}"
        end
        sleep 0.2
      end
    end
  end

  def verify_prs_needing_review(github_service, repository_name, repository_owner)
    Rails.logger.info "[FetchAllPullRequestsJob] Verifying PRs Needing Team Review for API lag..."

    backend_reviewers = BackendReviewGroupMember.pluck(:username)

    # Use database queries instead of loading all PRs into memory
    # Only fetch IDs first, then process in batches
    needs_review_pr_ids = PullRequest.where(
      state: "open",
      repository_name: repository_name || ENV["GITHUB_REPO"],
      repository_owner: repository_owner || ENV["GITHUB_OWNER"]
    )
    .where.not(backend_approval_status: "approved")
    .where(draft: false)
    .pluck(:id)

    Rails.logger.info "[FetchAllPullRequestsJob] Found #{needs_review_pr_ids.count} potential PRs to verify"

    updated_count = 0

    # Process in batches of 3 to minimize memory usage (reduced from 5)
    needs_review_pr_ids.each_slice(3) do |batch_ids|
      PullRequest.where(id: batch_ids).each do |pr|
        # Skip if truly exempt or already has approvals
        next if pr.truly_exempt_from_backend_review?
        next if pr.approval_summary && pr.approval_summary[:approved_count].to_i > 0
        next if pr.approval_summary && pr.approval_summary[:approved_users]&.any? { |user| backend_reviewers.include?(user) }
      begin
        # Delete existing reviews to force fresh fetch
        pr.pull_request_reviews.destroy_all

        # Fetch fresh reviews from GitHub
        reviews = github_service.pull_request_reviews(pr.number)

        # Create reviews in database
        reviews.each do |review_data|
          PullRequestReview.create!(
            pull_request_id: pr.id,
            github_id: review_data.id,
            user: review_data.user.login,
            state: review_data.state,
            submitted_at: review_data.submitted_at
          )
        end

        # Store old status to check if it changed
        old_status = pr.backend_approval_status

        # Update approval statuses
        pr.update_backend_approval_status!
        pr.update_ready_for_backend_review!
        pr.update_approval_status!
        pr.update_awaiting_author_changes!

        # Log if status changed
        if pr.backend_approval_status != old_status
          updated_count += 1
          Rails.logger.info "[FetchAllPullRequestsJob] PR ##{pr.number} status updated: #{old_status} -> #{pr.backend_approval_status}"
        end

        # Small delay to avoid rate limiting
        sleep 0.3

      rescue => e
        Rails.logger.error "[FetchAllPullRequestsJob] Error verifying PR ##{pr.number}: #{e.message}"
      end
      end

      # Force garbage collection after each batch
      GC.start(full_mark: false, immediate_sweep: true)
    end

    Rails.logger.info "[FetchAllPullRequestsJob] Verification complete. Updated #{updated_count} PRs"
  end

  def verify_prs_via_html_scraping(repository_name, repository_owner)
    Rails.logger.info "[FetchAllPullRequestsJob] Starting HTML scraping verification..."

    scraper = PrHtmlScraperService.new
    result = scraper.verify_prs_needing_review_via_html(repository_name, repository_owner)

    Rails.logger.info "[FetchAllPullRequestsJob] HTML scraping complete. Checked: #{result[:total_checked]}, Updated: #{result[:updated]}"

  rescue => e
    Rails.logger.error "[FetchAllPullRequestsJob] HTML scraping error: #{e.message}"
  end

  def fetch_pr_checks_inline(pr, github_service, hybrid_service)
    # Skip fetching reviews if PR is already backend-approved (saves API calls & memory)
    # We'll still check during deep verification
    unless pr.backend_approval_status == "approved"
      begin
        reviews = github_service.pull_request_reviews(pr.number)

        # Only update if we got reviews back
        if reviews.any?
          pr.pull_request_reviews.destroy_all
          reviews.each do |review_data|
            PullRequestReview.create!(
              pull_request_id: pr.id,
              github_id: review_data.id,
              user: review_data.user.login,
              state: review_data.state,
              submitted_at: review_data.submitted_at
            )
          end

          # Update approval statuses after fetching reviews
          pr.update_backend_approval_status!
          pr.update_awaiting_author_changes!
        end
      rescue => e
        Rails.logger.error "[FetchAllPullRequestsJob] Error fetching reviews for PR ##{pr.number}: #{e.message}"
      end
    end

    # Use shared HybridPrCheckerService for faster API-based check fetching
    result = hybrid_service.get_accurate_pr_checks(pr)

    # Update PR with check counts
    pr.update!(
      ci_status: result[:overall_status] || "unknown",
      total_checks: result[:total_checks] || 0,
      successful_checks: result[:successful_checks] || 0,
      failed_checks: result[:failed_checks] || 0,
      pending_checks: result[:pending_checks] || 0
    )

    # Store failing checks in cache for frontend
    if result[:failed_checks] > 0 && result[:checks].any?
      failing_checks = result[:checks].select { |c| [ "failure", "error", "cancelled", "pending" ].include?(c[:status]) }
      Rails.cache.write("pr_#{pr.id}_failing_checks", failing_checks, expires_in: 1.hour)
    else
      Rails.cache.delete("pr_#{pr.id}_failing_checks")
    end

    # SKIP storing check_runs during scraping to reduce memory usage
    # The counts are stored on the PR record, detailed checks can be fetched on-demand
    # Only store if there are actual failures that need investigation
    if result[:failed_checks] > 0 && result[:checks].any?
      pr.check_runs.destroy_all
      # Only store failed checks, not all checks
      failed_checks_data = result[:checks]
        .select { |c| %w[failure error cancelled].include?(c[:status]) }
        .first(10) # Limit to 10 to save memory
        .map do |check|
          {
            name: check[:name],
            status: check[:status] || "unknown",
            url: check[:url],
            description: check[:description],
            required: check[:required] || false,
            suite_name: check[:suite_name],
            pull_request_id: pr.id,
            created_at: Time.current,
            updated_at: Time.current
          }
        end
      CheckRun.insert_all(failed_checks_data) if failed_checks_data.any?
    end

    # SKIP commits check during scraping to reduce memory usage
    # The check will run lazily in changes_requested_info when needed by frontend

    # Update ready for backend review status
    pr.update_ready_for_backend_review!

    # Update approval status
    pr.update_approval_status!

  rescue => e
    Rails.logger.error "[FetchAllPullRequestsJob] Error fetching checks for PR ##{pr.number}: #{e.message}"
  end
end

require "ostruct"

class GithubService
  def initialize(owner: nil, repo: nil)
    @client = Octokit::Client.new(access_token: ENV["GITHUB_TOKEN"])
    @owner = owner || ENV["GITHUB_OWNER"]
    @repo = repo || ENV["GITHUB_REPO"]
  end

  def pull_requests(state: "open", per_page: 100)
    @client.pull_requests("#{@owner}/#{@repo}", state: state, per_page: per_page)
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error: #{e.message}"
    []
  end

  def all_pull_requests(state: "open")
    all_prs = []
    page = 1

    loop do
      prs = @client.pull_requests("#{@owner}/#{@repo}", state: state, per_page: 100, page: page)
      break if prs.empty?

      all_prs.concat(prs)
      page += 1

      # Safety check to prevent infinite loops
      break if page > 10 # Max 1000 PRs
    end

    all_prs
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error: #{e.message}"
    []
  end

  def pull_request(pr_number)
    @client.pull_request("#{@owner}/#{@repo}", pr_number)
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error: #{e.message}"
    nil
  end

  def pull_request_reviews(pr_number)
    # Use GraphQL API for more accurate review data
    # The REST API doesn't always return the latest reviews
    graphql_reviews(pr_number)
  rescue => e
    Rails.logger.error "GitHub API Error fetching reviews: #{e.message}"
    # Fallback to REST API if GraphQL fails.
    #
    # REST review objects carry raw integer `.id`s — a different ID space
    # than the SHA256-hashed GraphQL node IDs used everywhere else (see
    # graphql_reviews below and ReviewEvent). Callers that mirror reviews
    # into the durable review_events ledger MUST check `id_space` and skip
    # anything tagged "rest", or the same review can be double-counted once
    # under its REST id here and again later under its GraphQL id once a
    # healthy scrape or the nightly backfill records it canonically.
    begin
      rest_reviews = @client.pull_request_reviews("#{@owner}/#{@repo}", pr_number)
      rest_reviews.each { |review| review.define_singleton_method(:id_space) { "rest" } }
      rest_reviews
    rescue Octokit::Error => rest_error
      Rails.logger.error "GitHub REST API Error (fallback): #{rest_error.message}"
      []
    end
  end

  def graphql_reviews(pr_number)
    # Fetch ALL reviews (not just latestReviews) so we can properly determine
    # the latest actionable review per user. This is needed because:
    # - When a user approves AND comments, GitHub creates 2 review records
    # - latestReviews only returns one review per user (often the COMMENT, not APPROVAL)
    # - We need all reviews to find the latest APPROVED/CHANGES_REQUESTED per user
    query = <<~GRAPHQL
      query {
        repository(owner: "#{@owner}", name: "#{@repo}") {
          pullRequest(number: #{pr_number}) {
            reviewDecision
            reviews(last: 100) {
              nodes {
                author {
                  login
                }
                state
                submittedAt
                id
              }
            }
          }
        }
      }
    GRAPHQL

    result = @client.post("/graphql", { query: query }.to_json)

    if result && result[:data] && result[:data][:repository] && result[:data][:repository][:pullRequest]
      pr_data = result[:data][:repository][:pullRequest]
      reviews = pr_data[:reviews][:nodes]

      # Convert GraphQL format to match REST API format for compatibility
      # Filter out reviews with nil authors (deleted users)
      reviews.filter_map do |review|
        next if review[:author].nil?

        OpenStruct.new(
          id: Digest::SHA256.hexdigest(review[:id]).to_i(16) % (2**62), # Stable hash from GraphQL ID
          user: OpenStruct.new(login: review[:author][:login]),
          state: review[:state],
          submitted_at: Time.parse(review[:submittedAt]),
          id_space: "graphql"
        )
      end
    else
      Rails.logger.error "GraphQL query returned unexpected structure: #{result.inspect}"
      []
    end
  rescue => e
    Rails.logger.error "GraphQL Error fetching reviews: #{e.message}"
    raise e
  end

  def pull_request_diff_stats(state: "OPEN")
    # Bulk-fetch additions/deletions/changedFiles for every open PR in a
    # couple of paginated GraphQL calls. The REST list endpoint used by
    # all_pull_requests doesn't return these fields at all — only the
    # single-PR REST endpoint does, which would mean one extra REST call
    # per PR per scrape. GraphQL's list query returns them for free, so a
    # repo with ~150 open PRs costs 2 GraphQL calls instead of 150 REST ones.
    stats = {}
    cursor = nil

    loop do
      query = <<~GRAPHQL
        query {
          repository(owner: "#{@owner}", name: "#{@repo}") {
            pullRequests(states: #{state}, first: 100#{cursor ? ", after: \"#{cursor}\"" : ""}) {
              nodes {
                number
                additions
                deletions
                changedFiles
              }
              pageInfo {
                hasNextPage
                endCursor
              }
            }
          }
        }
      GRAPHQL

      result = @client.post("/graphql", { query: query }.to_json)
      prs_connection = result&.dig(:data, :repository, :pullRequests)

      unless prs_connection
        Rails.logger.error "GraphQL query returned unexpected structure: #{result.inspect}"
        break
      end

      prs_connection[:nodes].each do |node|
        stats[node[:number]] = {
          additions: node[:additions],
          deletions: node[:deletions],
          changed_files: node[:changedFiles]
        }
      end

      page_info = prs_connection[:pageInfo]
      break unless page_info[:hasNextPage]

      cursor = page_info[:endCursor]
    end

    stats
  rescue => e
    Rails.logger.error "GraphQL Error fetching diff stats: #{e.message}"
    stats
  end

  def pull_request_comments(pr_number)
    # Note: In GitHub API, PR comments (issue comments) are different from review comments
    # This fetches issue comments (regular comments on the PR thread)
    @client.issue_comments("#{@owner}/#{@repo}", pr_number)
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error fetching PR comments: #{e.message}"
    []
  end

  def pull_request_review_comments(pr_number)
    # Line-level review comments (the threaded ⚠️/❗ feedback inside reviews).
    # Distinct from issue_comments (PR conversation) and reviews (formal
    # APPROVE/CHANGES_REQUESTED). These are what reviewers leave when they
    # say "this method needs refactoring" without formally requesting changes.
    @client.pull_request_comments("#{@owner}/#{@repo}", pr_number)
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error fetching review comments: #{e.message}"
    []
  end

  def pull_request_with_reviews(pr_number)
    pr = @client.pull_request("#{@owner}/#{@repo}", pr_number)
    reviews = pull_request_reviews(pr_number)

    {
      pr: pr,
      reviews: reviews
    }
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error: #{e.message}"
    nil
  end

  def rate_limit
    @client.rate_limit
  end

  def search_pull_requests(query:, per_page: 30)
    @client.search_issues(query, per_page: per_page)
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error searching PRs: #{e.message}"
    OpenStruct.new(total_count: 0, items: [])
  end

  def commit_status(sha)
    @client.combined_status("#{@owner}/#{@repo}", sha)
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error fetching commit status: #{e.message}"
    nil
  end

  def commit_statuses(sha)
    @client.statuses("#{@owner}/#{@repo}", sha)
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error fetching commit statuses: #{e.message}"
    []
  end

  def check_suites(sha)
    @client.check_suites("#{@owner}/#{@repo}", sha)
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error fetching check suites: #{e.message}"
    nil
  end

  def check_runs_for_suite(check_suite_id)
    @client.check_runs_for_suite("#{@owner}/#{@repo}", check_suite_id)
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error fetching check runs: #{e.message}"
    nil
  end

  def get_ci_status(pr)
    # Use web scraping to get CI status from the PR page
    scraper = GithubScraperService.new(owner: @owner, repo: @repo)
    scraper.scrape_pr_checks(pr.html_url)
  rescue => e
    Rails.logger.error "Error getting CI status for PR: #{e.message}"
    {
      overall_status: "error",
      failing_checks: [],
      total_checks: 0
    }
  end

  def pull_request_commits(pr_number)
    @client.pull_request_commits("#{@owner}/#{@repo}", pr_number)
  rescue Octokit::Error => e
    Rails.logger.error "GitHub API Error fetching PR commits: #{e.message}"
    []
  end

  private

  def repository_path
    "#{@owner}/#{@repo}"
  end
end

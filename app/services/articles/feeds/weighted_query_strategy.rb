module Articles
  module Feeds
    # @api private
    #
    # This is an experimental object that we're refining to be a
    # competetor to the existing feed strategies.
    #
    # At present, there are no optimizations.  They could include:
    #
    # 1) Eager loading of objects relevant for articles in the feed.
    # 2) Is there a better query structure for these concerns?
    #
    # I've also chosen to atomize the SQL statement construction to highlight
    # how we might parameterize the various weights, or even swap out
    # multiplicative methods for additive methods.
    #
    # @note One possible short-coming is that the query does not
    #   account for the Forem's administrators.
    # @note For those considering extending this, be very mindful of
    #   SQL injection.
    class WeightedQueryStrategy
      # This constant defines the allowable relevance scoring methods.
      # A scoring method should be a SQL fragement that produces a
      # value between 0 and 1.
      #
      # Keys:
      #
      # - clause: The SQL clause statement
      # - cases: An Array of Arrays, the first value is what matches
      #          the clause, the second value is the multiplicative
      #          factor.
      # - fallback: When no case is matched use this factor.
      SCORING_METHOD_CONFIGURATIONS = {
        # Weight to give based on the age of the article.
        daily_decay_factor: {
          clause: "(current_date - published_at::date)",
          cases: [
            [0, 1], [1, 0.95], [2, 0.9],
            [3, 0.85], [4, 0.8], [5, 0.75],
            [6, 0.7], [7, 0.65], [8, 0.6],
            [9, 0.55], [10, 0.5], [11, 0.4],
            [12, 0.3], [13, 0.2], [14, 0.1]
          ],
          fallback: 0
        },
        # Weight to give based on spaminess of the article.
        spaminess_factor: {
          clause: "articles.spaminess_rating",
          cases: [[0, 1]],
          fallback: 0.05
        },
        # Weight to give based on the difference between experience
        # level of the article and given user.
        experience_factor: {
          clause: "ABS(articles.experience_level_rating - (SELECT
              (CASE
                 WHEN experience_level IS NULL THEN :default_user_experience_level
                 ELSE experience_level END ) AS user_experience_level
              FROM users_settings WHERE users_settings.user_id = :user_id
            ))",
          cases: [[0, 1], [1, 0.98], [2, 0.97], [3, 0.96], [4, 0.95], [5, 0.94]],
          fallback: 0.93
        },
        # Weight to give for number of comments to the article from
        # other users that the given user follows.
        comment_count_by_those_followed_factor: {
          clause: "COUNT(comments.id)",
          cases: [[0, 0.95], [1, 0.98], [2, 0.99]],
          fallback: 0.93
        },
        # Weight to give an article based on it's most recent comment.
        latest_comment_factor: {
          clause: "(current_date - MAX(comments.created_at)::date)",
          cases: [[0, 1], [1, 0.9988]],
          fallback: 0.988
        },
        # Weight to give for the number of intersecting tags the given
        # user follows and the article has.
        matching_tags_factor: {
          clause: "COUNT(followed_tags.follower_id)",
          cases: [[0, 0.4], [1, 0.9]],
          fallback: 1
        },
        # Weight to give when the given user follows the article's
        # author.
        following_author_factor: {
          clause: "COUNT(followed_user.follower_id)",
          cases: [[0, 0.8], [1, 1]],
          fallback: 1
        },
        # Weight to give to the number of comments on the article.
        comments_count_factor: {
          clause: "articles.comments_count",
          cases: [[0, 0.9], [1, 0.94], [2, 0.95], [3, 0.98], [4, 0.999]],
          fallback: 1
        },
        # Weight to give for the number of reactions on the article.
        reactions_factor: {
          clause: "articles.reactions_count",
          cases: [[0, 0.9988], [1, 0.9988], [2, 0.9988], [3, 0.9988]],
          fallback: 1
        },
        # Weight to give to the when the given user follows the
        # article's organization.
        following_org_factor: {
          clause: "COUNT(followed_org.follower_id)",
          cases: [[0, 0.95], [1, 1]],
          fallback: 1
        }
      }.freeze

      DEFAULT_USER_EXPERIENCE_LEVEL = 5

      # @param user [User] who are we querying for?
      # @param number_of_articles [Integer] how many articles are we
      #   returning
      # @param page [Integer] what is the pagination page
      # @param tag [String, nil] this isn't implemented in other feeds
      #   so we'll see
      # @param config [Hash<Symbol, Object>] a list of configurations,
      #   see {#initialize} implementation details.
      # @option config [Array<Symbol>] :scoring_configs
      #   allows for you to configure which methods you want to use.
      #   This is most relevant when running A/B testing.
      #
      # @todo I envision that we will tweak the factors we choose, so
      #   those will likely need some kind of structured consideration.
      def initialize(user: nil, number_of_articles: 50, page: 1, tag: nil, **config)
        @user = user
        @number_of_articles = number_of_articles.to_i
        @page = page
        @tag = tag
        @default_user_experience_level = config.fetch(:default_user_experience_level) { DEFAULT_USER_EXPERIENCE_LEVEL }
        @scoring_configs = config.fetch(:scoring_configs) { default_scoring_configs }
        configure!(scoring_configs: @scoring_configs)
      end

      # The goal of this query is to generate a list of articles that
      # are relevant to the user's interest.
      #
      # First we give a score to an article based on it's publication
      # date.  The max possible score is 1.
      #
      # Then we begin multiplying that score by numbers between 0 and
      # 1.  The closer that multiplier is to 1 the "more relevant"
      # that factor is to the user.
      #
      # @todo Need to impliment a common interface for the
      # Articles::Feeds for both Basic and LargeForemExperimental as
      # well as the signed in and not signed in cases.
      def call
        Article.find_by_sql([
                              the_sql_statement,
                              {
                                user_id: @user.id,
                                number_of_results: @number_of_articles.to_i,
                                default_user_experience_level: @default_user_experience_level.to_i
                              },
                            ])
      end

      private

      # The relevance score components speak.  Those method
      # implementations are deeply entwined with the SQL statements.
      #
      # @todo Remember to not use "SELECT articles.*" which will
      # probably mean I want to use AREL project.
      def the_sql_statement
        <<~THE_SQL_STATEMENT
          WITH top_articles AS (
            SELECT articles.id,
            (#{relevance_score_components_as_sql}) AS relevance_score
            FROM articles
            LEFT OUTER JOIN taggings
              ON taggings.taggable_id = articles.id
                AND taggable_type = 'Article'
            INNER JOIN tags
              ON taggings.tag_id = tags.id
            LEFT OUTER JOIN follows AS followed_tags
              ON tags.id = followed_tags.followable_id
                AND followed_tags.followable_type = 'ActsAsTaggableOn::Tag'
                AND followed_tags.follower_type = 'User'
                AND followed_tags.follower_id = :user_id
            LEFT OUTER JOIN follows AS followed_user
              ON articles.user_id = followed_user.followable_id
                AND followed_user.followable_type = 'User'
                AND followed_user.follower_id = :user_id
                AND followed_user.follower_type = 'User'
            LEFT OUTER JOIN follows AS followed_org
              ON articles.organization_id = followed_org.followable_id
                AND followed_org.followable_type = 'Organization'
                AND followed_org.follower_id = :user_id
                AND followed_org.follower_type = 'User'
            LEFT OUTER JOIN comments
              ON comments.commentable_id = articles.id
                AND comments.commentable_type = 'Article'
                AND followed_user.followable_id = comments.user_id
                AND followed_user.followable_type = 'User'
            LEFT OUTER JOIN user_blocks
              ON user_blocks.blocked_id = articles.user_id
                AND user_blocks.blocked_id IS NULL
                AND user_blocks.blocker_id = :user_id
            WHERE published = true
            GROUP BY articles.id,
              articles.title,
              articles.published_at,
              articles.comments_count,
              articles.experience_level_rating,
              articles.spaminess_rating,
              articles.reactions_count
            ORDER BY relevance_score DESC,
              articles.published_at DESC
            LIMIT :number_of_results)
          SELECT articles.*
          FROM articles
          INNER JOIN top_articles
            ON top_articles.id = articles.id
            ORDER BY articles.published_at DESC;
        THE_SQL_STATEMENT
      end

      # The current factors are as follows:
      #
      # 1. Proximity of article's experience level rating to user's experience level.
      # 2. If someone the user follows has commented on the article.
      # 3. The number of article tags that intersect with the user.
      # 4. If the user follows the article's author.
      # 5. If the user follows the article's author's organization.
      # 6. The spaminess of the article.
      def relevance_score_components_as_sql
        relevance_score_components.join(" * ")
      end

      # By default, we use the scoring methods that are possible.
      def default_scoring_configs
        SCORING_METHOD_CONFIGURATIONS
      end

      def configure!(scoring_configs:)
        @relevance_score_components = []
        SCORING_METHOD_CONFIGURATIONS.each_pair do |valid_method_name, default_config|
          # Ensuring that we only use valid scoring configs
          next unless scoring_configs.key?(valid_method_name)

          scoring_config = scoring_configs.fetch(valid_method_name)
          # The caller chose not to configure this.
          scoring_config = default_config if scoring_config.is_a?(Hash)

          # Don't trust them to send a valid clause.  That's the path of SQL injection.
          scoring_config[:clause] = default_config.fetch(:clause)
          @relevance_score_components << build_score_element_from(**scoring_config)
        end
      end

      attr_reader :relevance_score_components

      # @param clause [String]
      # @param cases [Array<Array<#to_i, #to_f>>]
      # @param fallback [#to_f]
      def build_score_element_from(clause:, cases:, fallback:)
        text = "(CASE #{clause}"
        cases.each do |value, factor|
          text += "\nWHEN #{value.to_i} THEN #{factor.to_f}"
        end
        text += "\nELSE #{fallback.to_f} END)"
      end
    end
  end
end

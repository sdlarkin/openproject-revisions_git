module OpenProject::GitHosting
  module Patches
    module RepositoriesControllerPatch

      def self.included(base)
        base.class_eval do
          unloadable

          include InstanceMethods

          alias_method_chain :show,    :git_hosting
          # TODO
          alias_method_chain :edit,  :git_hosting
          # alias_method_chain :update,  :git_hosting
          alias_method_chain :destroy, :git_hosting

          helper :git_hosting
        end
      end

      module InstanceMethods

        def show_with_git_hosting(&block)
          if @repository.is_a?(Repository::Git) and @rev.blank?
            # Fake list of repos
            @repositories = @project.gitolite_repos
            render :action => 'git_instructions'
          else
            show_without_git_hosting(&block)
          end
        end


        def edit_with_git_hosting

          # Check if repository has been created before
          @repository = @project.repository
          if !@repository
            @repository = Repository.factory(params[:repository_scm])
            @repository.project = @project if @repository
          end

          edit_without_git_hosting

          # Create Gitolite Repository after completed edit
          if request.post? && @repository.is_a?(Repository::Git) && !@repository.errors.any?

              OpenProject::GitHosting::GitHosting.logger.info("User '#{User.current.login}' created a new repository '#{@repository.gitolite_repository_name}'")
              OpenProject::GitHosting::GitoliteWrapper.update(:add_repository, @repository.id)
          end
        end


        def update_with_git_hosting(&block)
          update_without_git_hosting(&block)

          if @repository.is_a?(Repository::Git)
            if !@repository.errors.any?

              params[:extra][:git_daemon] = params[:extra][:git_daemon] == 'true' ? true : false
              params[:extra][:git_notify] = params[:extra][:git_notify] == 'true' ? true : false

              update_default_branch = false

              if params[:extra].has_key?(:default_branch) && @repository.extra[:default_branch] != params[:extra][:default_branch]
                update_default_branch = true
              end

              ## Update attributes
              @repository.extra.update_attributes(params[:extra])

              ## Update repository
              OpenProject::GitHosting::GitHosting.logger.info("User '#{User.current.login}' has modified repository '#{@repository.gitolite_repository_name}'")
              OpenProject::GitHosting::GitoliteWrapper.update(:update_repository, @repository.id)

              ## Update repository default branch
              if update_default_branch
                OpenProject::GitHosting::GitHosting.logger.info("User '#{User.current.login}' has modified default_branch of '#{@repository.gitolite_repository_name}' ('#{@repository.extra[:default_branch]}')")
                OpenProject::GitHosting::GitoliteWrapper.update(:update_repository_default_branch, @repository.id)
              end
            end
          end
        end


        def destroy_with_git_hosting(&block)
          destroy_without_git_hosting(&block)

          if @repository.is_a?(Repository::Git)
            if !@repository.errors.any?
              OpenProject::GitHosting::GitHosting.logger.info("User '#{User.current.login}' has removed repository '#{@repository.gitolite_repository_name}'")
              repository_data = {}
              repository_data['repo_name'] = @repository.gitolite_repository_name
              repository_data['repo_path'] = @repository.gitolite_repository_path
              OpenProject::GitHosting::GitoliteWrapper.update(:delete_repositories, [repository_data])
            end
          end
        end


      end
    end
  end
end

RepositoriesController.send(:include, OpenProject::GitHosting::Patches::RepositoriesControllerPatch)

  class GitolitePublicKey < ActiveRecord::Base
  unloadable

  KEY_TYPE_USER = 0
  KEY_TYPE_DEPLOY = 1

  DEPLOY_PSEUDO_USER = "deploy_key"

  belongs_to :user

  scope :user_key,   -> { where key_type: KEY_TYPE_USER }
  scope :deploy_key, -> { where key_type: KEY_TYPE_DEPLOY }

  validates_presence_of   :title, :identifier, :key, :key_type
  validates_inclusion_of  :key_type, :in => [KEY_TYPE_USER, KEY_TYPE_DEPLOY]

  validates_uniqueness_of :title,      :scope => :user_id
  validates_uniqueness_of :identifier, :scope => :user_id

  validates_format_of :title, :with => /\A[a-z0-9_\-]*\z/i

  validate :has_not_been_changed
  validate :key_correctness
  validate :key_uniqueness

  before_validation :set_identifier
  before_validation :set_fingerprint
  before_validation :strip_whitespace
  before_validation :remove_control_characters

  after_commit ->(obj) { obj.add_ssh_key },     on: :create
  after_commit ->(obj) { obj.destroy_ssh_key }, on: :destroy


  def self.by_user(user)
    where("user_id = ?", user.id)
  end

  # Returns the path to this key under the gitolite keydir
  # resolves to <user.gitolite_identifier>/<title>/<identifier>.pub
  #
  # The root folder for this user is the user's identifier
  # for logical grouping of their keys, which are organized
  # by their title in subfolders.
  #
  # This is due to the new gitolite multi-keys organization
  # using folders. See http://gitolite.com/gitolite/users.html
  def key_path
    File.join(self.user.gitolite_identifier, self.title, self.identifier)
  end

  def to_s
    title
  end

  # Returns the unique identifier for this key based on the key_type
  #
  # For user public keys, this simply is the user's gitolite_identifier.
  # For deployment keys, we use an incrementing number.
  def set_identifier
    self.identifier ||=
      begin
        case key_type
          when KEY_TYPE_USER
            self.user.gitolite_identifier
          when KEY_TYPE_DEPLOY
            "#{self.user.gitolite_identifier}_#{DEPLOY_PSEUDO_USER}"
          else
            nil
        end
      end
  end

  # Key type checking functions
  def user_key?
    key_type == KEY_TYPE_USER
  end


  def deploy_key?
    key_type == KEY_TYPE_DEPLOY
  end

  protected

  def add_ssh_key
    OpenProject::Revisions::Git::GitoliteWrapper.update(:add_ssh_key, self)
  end


  def destroy_ssh_key
    OpenProject::Revisions::Git::GitoliteWrapper.logger.info("User '#{User.current.login}' has deleted a SSH key")

    repo_key = { title: self.title, key: self.key, location: self.title, owner: self.identifier, identifier: self.identifier }

    OpenProject::Revisions::Git::GitoliteWrapper.update(:delete_ssh_key, repo_key)
  end


  private

  def set_fingerprint
    file = Tempfile.new('keytest')
    file.write(key)
    file.close
    # This will throw if exitcode != 0
    output = OpenProject::Revisions::Shell.capture_out('ssh-keygen', '-l', '-f', file.path)
    if output
      self.fingerprint = output.split[1]
    end
  rescue => e
    errors.add(:key, l(:error_key_corrupted))
  ensure
    file.unlink
  end


  # Strip leading and trailing whitespace
  def strip_whitespace
    self.title = title.strip

    # Don't mess with existing keys (since cannot change key text anyway)
    if new_record?
      self.key = key.strip
    end
  end


  # Remove control characters from key
  def remove_control_characters
    # Don't mess with existing keys (since cannot change key text anyway)
    return if !new_record?

    # First -- let the first control char or space stand (to divide key type from key)
    # Really, this is catching a special case in which there is a \n between type and key.
    # Most common case turns first space back into space....
    self.key = key.sub(/[ \r\n\t]/, ' ')

    # Next, if comment divided from key by control char, let that one stand as well
    # We can only tell this if there is an "=" in the key. So, won't help 1/3 times.
    self.key = key.sub(/=[ \r\n\t]/, '= ')

    # Delete any remaining control characters....
    self.key = key.gsub(/[\a\r\n\t]/, '').strip
  end


  def has_not_been_changed
    unless new_record?
      has_errors = false

      %w(identifier key user_id key_type).each do |attribute|
        method = "#{attribute}_changed?"
        if self.send(method)
          errors.add(attribute, 'may not be changed')
          has_errors = true
        end
      end

      return has_errors
    end
  end


  def key_correctness
    # Test correctness of fingerprint from output
    # and general ssh-(r|d|ecd)sa <key> <id> structure
    (self.fingerprint =~ /^(\w{2}:?)+$/i) &&
    (key.match(/^(\S+)\s+(\S+)/))
  end

  def key_uniqueness
    return if !new_record?

    existing = GitolitePublicKey.find_by_fingerprint(self.fingerprint)
    if existing
      # Hm.... have a duplicate key!
      if existing.user == User.current
        errors.add(:key, l(:error_key_in_use_by_you, :name => existing.title))
        return false
      elsif User.current.admin?
        errors.add(:key, l(:error_key_in_use_by_other, :login => existing.user.login, :name => existing.title))
        return false
      else
        errors.add(:key, l(:error_key_in_use_by_someone))
        return false
      end
    end
    true
  end

end

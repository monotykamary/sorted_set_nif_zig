pub const Configuration = struct {
    /// Maximum number of items a bucket can hold before splitting.
    max_bucket_size: usize = 200,
    /// Initial capacity for the bucket list.
    initial_set_capacity: usize = 0,

    pub fn init(max_bucket_size: usize, initial_set_capacity: usize) Configuration {
        return .{ .max_bucket_size = max_bucket_size, .initial_set_capacity = initial_set_capacity };
    }

    pub fn default() Configuration {
        return .{};
    }
};

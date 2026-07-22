# Check if running in Docker
if [ -f /.dockerenv ]; then
    echo "Running in Docker"
else
    echo "Not running in Docker"
fi
document.addEventListener('DOMContentLoaded', function() {
    const form = document.getElementById('deployForm');
    const startButton = document.getElementById('startButton');

    startButton.addEventListener('click', function(event) {
        event.preventDefault();
        
        const formData = new FormData(form);
        const data = {};
        formData.forEach((value, key) => {
            data[key] = value;
        });

        fetch('/api/deploy', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(data)
        })
        .then(response => response.json())
        .then(result => {
            alert(result.message);
        })
        .catch(error => {
            console.error('Error:', error);
            alert('An error occurred while starting the deployment.');
        });
    });
});